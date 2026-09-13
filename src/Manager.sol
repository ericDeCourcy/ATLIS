// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {LadderProxy} from "./LadderProxy.sol";
import {Placement} from "./lib/Placement.sol";
import {StrategyBuilder} from "./lib/StrategyBuilder.sol";
import {OracleLib, IAggregatorV3} from "./lib/OracleLib.sol";
import {ISwapRouter02, IQuoterV2} from "./interfaces/IUniswapV3.sol";

/// @title Manager
/// @notice Brain of the ATLIS ladder. Owns two permanent LadderProxy children
///         (USDC-seeded buy side, WETH-seeded sell side), holds dry powder,
///         performs all accounting, and executes Uniswap v3 trades directly at
///         each rebalance. See specs.md.
///
/// @dev ACCOUNTING (spec §8). One source of truth: `costBasisUsdc`, the USDC
///      paid for the WETH currently held (`inventoryWeth`). `avgEntry` derives
///      from the two. Buys add to both; sells remove a proportional slice of
///      both, so avgEntry is unchanged by sells and falls only on acquisition.
///      Realized proceeds are split (tax + profit swept out, principal left in
///      the balance to re-enter via the powder drip) and not persisted.
///
///      DECIMALS. USDC 6, WETH 18. Prices are WAD (1e18) USDC-per-WETH, the
///      units RungMath / Placement / OracleLib all speak.
contract Manager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    /// @dev avgEntry(WAD) = costBasisUsdc * 1e30 / inventoryWeth.
    ///      (costBasisUsdc/1e6) / (inventoryWeth/1e18) * 1e18 = *1e30.
    uint256 internal constant AVG_SCALE = 1e30;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    LadderProxy public immutable buyProxy; // USDC-seeded; rungs below the ladder
    LadderProxy public immutable sellProxy; // WETH-seeded; rungs above

    IERC20 public immutable usdc; // 6 decimals
    IERC20 public immutable weth; // 18 decimals

    uint256 public immutable anchor; // rung-1000 price, WAD
    address public immutable aquaApp; // the Aqua router (SwapVM) proxies ship to

    IAggregatorV3 public immutable priceFeed;
    ISwapRouter02 public immutable swapRouter;
    IQuoterV2 public immutable quoter;
    uint24 public immutable poolFee; // Uniswap v3 fee tier (lowest with liquidity)

    // ---- strategy parameters (immutable; redeploy to change, per §14) ----
    uint256 public immutable rebalancePeriod; // seconds between periodic rebalances
    uint256 public immutable newPowderPerPeriod; // USDC made-ready each period (the drip / cap)
    uint256 public immutable purchPct; // bps of dry powder that sizes the round budget
    uint256 public immutable growthPct; // bps of budget spent immediately on Uniswap
    uint256 public immutable decayPct; // bps of WETH sold immediately on Uniswap
    uint256 public immutable minBuy; // floor on the round budget, USDC
    uint256 public immutable minSell; // floor on an immediate sell, WETH
    uint256 public immutable taxPct; // bps of realized PROFIT sent to taxDest
    uint256 public immutable maxStaleness; // max oracle age, seconds (0 disables)

    /*//////////////////////////////////////////////////////////////
                             MUTABLE CONFIG
    //////////////////////////////////////////////////////////////*/

    address public profitDest; // realized profit (net of tax) is swept here
    address public taxDest; // realized tax is swept here
    uint256 public slippageBps; // max slippage vs oracle spot on Uniswap fills

    /*//////////////////////////////////////////////////////////////
                                ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    uint256 public costBasisUsdc; // USDC paid for currently held WETH
    uint256 public inventoryWeth; // WETH currently held (across Manager + proxies)

    uint256 public dryPowder; // USDC made ready to deploy, not yet converted
    uint256 public lastRebalance; // timestamp of the last rebalance

    // Seed amounts recorded at ship, so a period's net delta = seed - remaining.
    uint256 public lastBuySeedUsdc;
    uint256 public lastSellSeedWeth;

    // Harvested (acquired) tokens pulled mid-period, folded in at next rebalance.
    uint256 public harvestedWethFromBuy;
    uint256 public harvestedUsdcFromSell;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event BuysBooked(uint256 usdcSpent, uint256 wethBought, uint256 avgEntryWad);
    event SellsBooked(
        uint256 wethSold, uint256 usdcReceived, uint256 costOfSold, uint256 taxPaid, uint256 profitPaid
    );
    event PowderReplenished(uint256 dryPowder);
    event Rebalanced(uint256 spotWad, uint256 avgEntryWad, uint256 dryPowder);
    event Harvested(bool buySide, uint256 amount);
    event EmergencyDocked();
    event DestsUpdated(address profitDest, address taxDest);
    event SlippageUpdated(uint256 slippageBps);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error BadConfig();
    error NotDue();
    error NotImplemented();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Grouped to dodge stack-too-deep and keep the wiring legible.
    struct Config {
        address aqua; // Aqua registry (only needed to deploy the proxies)
        address aquaApp; // Aqua router the proxies ship strategies to
        address usdc;
        address weth;
        uint256 anchor; // rung-1000 price, WAD
        address priceFeed;
        address swapRouter;
        address quoter;
        uint24 poolFee;
        uint256 rebalancePeriod;
        uint256 newPowderPerPeriod;
        uint256 purchPct;
        uint256 growthPct;
        uint256 decayPct;
        uint256 minBuy;
        uint256 minSell;
        uint256 taxPct;
        address profitDest;
        address taxDest;
        uint256 slippageBps;
        uint256 maxStaleness;
    }

    constructor(Config memory c) Ownable(msg.sender) {
        if (
            c.aqua == address(0) || c.aquaApp == address(0) || c.usdc == address(0)
                || c.weth == address(0) || c.priceFeed == address(0) || c.swapRouter == address(0)
                || c.quoter == address(0) || c.profitDest == address(0) || c.taxDest == address(0)
        ) revert ZeroAddress();
        if (c.anchor == 0) revert BadConfig();
        if (
            c.purchPct > BPS || c.growthPct > BPS || c.decayPct > BPS || c.taxPct > BPS
                || c.slippageBps > BPS
        ) revert BadConfig();

        usdc = IERC20(c.usdc);
        weth = IERC20(c.weth);
        anchor = c.anchor;
        aquaApp = c.aquaApp;
        priceFeed = IAggregatorV3(c.priceFeed);
        swapRouter = ISwapRouter02(c.swapRouter);
        quoter = IQuoterV2(c.quoter);
        poolFee = c.poolFee;

        rebalancePeriod = c.rebalancePeriod;
        newPowderPerPeriod = c.newPowderPerPeriod;
        purchPct = c.purchPct;
        growthPct = c.growthPct;
        decayPct = c.decayPct;
        minBuy = c.minBuy;
        minSell = c.minSell;
        taxPct = c.taxPct;
        maxStaleness = c.maxStaleness;

        profitDest = c.profitDest;
        taxDest = c.taxDest;
        slippageBps = c.slippageBps;

        // Deploy the two permanent proxies, owned by this Manager.
        buyProxy = new LadderProxy(c.aqua, c.usdc, c.weth, c.anchor, true, address(this));
        sellProxy = new LadderProxy(c.aqua, c.usdc, c.weth, c.anchor, false, address(this));

        // Standing approvals for Manager-side Uniswap swaps.
        IERC20(c.usdc).forceApprove(c.swapRouter, type(uint256).max);
        IERC20(c.weth).forceApprove(c.swapRouter, type(uint256).max);

        lastRebalance = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                               ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Average entry price, WAD USDC/WETH. Zero when inventory is empty.
    function avgEntryWad() public view returns (uint256) {
        if (inventoryWeth == 0) return 0;
        return costBasisUsdc * AVG_SCALE / inventoryWeth;
    }

    /// @dev Fold an acquisition into cost basis. avgEntry moves toward the fill.
    function _bookBuys(uint256 usdcSpent, uint256 wethBought) internal {
        if (wethBought == 0) return;
        costBasisUsdc += usdcSpent;
        inventoryWeth += wethBought;
        emit BuysBooked(usdcSpent, wethBought, avgEntryWad());
    }

    /// @dev Fold a disposal in. Removes a proportional slice of both basis and
    ///      inventory (avgEntry unchanged), then splits proceeds: tax + net
    ///      profit are swept out; recovered principal is left in the Manager's
    ///      USDC balance to re-enter deployment only via the powder drip.
    ///      A loss-making sell books the reduced basis and sweeps nothing.
    function _bookSells(uint256 wethSold, uint256 usdcReceived) internal {
        if (wethSold == 0) return;

        uint256 costOfSold;
        if (wethSold >= inventoryWeth) {
            // Full (or over-) exit: attribute the entire remaining basis and
            // zero both, killing integer-division dust.
            costOfSold = costBasisUsdc;
            inventoryWeth = 0;
            costBasisUsdc = 0;
        } else {
            costOfSold = costBasisUsdc * wethSold / inventoryWeth;
            inventoryWeth -= wethSold;
            costBasisUsdc -= costOfSold;
        }

        uint256 taxPaid;
        uint256 profitPaid;
        if (usdcReceived > costOfSold) {
            uint256 profit = usdcReceived - costOfSold;
            taxPaid = profit * taxPct / BPS;
            profitPaid = profit - taxPaid;
            if (taxPaid != 0) usdc.safeTransfer(taxDest, taxPaid);
            if (profitPaid != 0) usdc.safeTransfer(profitDest, profitPaid);
        }

        emit SellsBooked(wethSold, usdcReceived, costOfSold, taxPaid, profitPaid);
    }

    /*//////////////////////////////////////////////////////////////
                              DRY POWDER
    //////////////////////////////////////////////////////////////*/

    /// @dev Make one period's USDC ready, capped at USDC actually held. MUST be
    ///      called after proxies are swept back and before redeploying, so
    ///      balanceOf reflects all owned USDC.
    function _replenishPowder() internal {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 target = dryPowder + newPowderPerPeriod;
        dryPowder = target < bal ? target : bal;
        emit PowderReplenished(dryPowder);
    }

    /// @notice The round's buy budget: min(max(purchPct·dryPowder, minBuy), dryPowder).
    function roundBudget() public view returns (uint256) {
        uint256 pct = dryPowder * purchPct / BPS;
        uint256 floored = pct > minBuy ? pct : minBuy;
        return floored < dryPowder ? floored : dryPowder;
    }

    /*//////////////////////////////////////////////////////////////
                           REBALANCE  (stubbed)
    //////////////////////////////////////////////////////////////*/

    /// @notice Keeper-triggered rebalance. Phases follow spec §6.
    /// @dev Internals are stubbed pending the next build step; the top-level
    ///      flow is fixed so the accounting above can be reviewed in isolation.
    function rebalance() external onlyOwner nonReentrant {
        if (block.timestamp < lastRebalance + rebalancePeriod && !_earlyTrigger()) revert NotDue();

        // 1. Observe + account: dock both, sweep to Manager, fold each proxy's
        //    net delta (+ harvested counters) into cost basis, reset counters.
        _collectAndAccount();

        // 2. Read spot; top up dry powder; bootstrap if we hold nothing.
        uint256 spot = OracleLib.readSpotWad(priceFeed, maxStaleness);
        _replenishPowder();
        if (inventoryWeth == 0) _bootstrap(spot);

        // 3. Immediate Uniswap trades, decided off the avg-only band and gated
        //    by a QuoterV2 simulation (one-sided: better-than-threshold always
        //    executes). Books the fills into cost basis.
        _maybeImmediateBuy(spot);
        _maybeImmediateSell(spot);

        // 4. Placement (spot-clamped + 0.5% buffer) and ladder deployment.
        Placement.Bands memory bands = Placement.compute(anchor, spot, avgEntryWad());
        _deployBuyLadder(bands);
        _deploySellLadder(bands);

        lastRebalance = block.timestamp;
        emit Rebalanced(spot, avgEntryWad(), dryPowder);
    }

    /// @dev Early trigger: spot outside the outermost live rung on either side
    ///      (§6). Stubbed to false for now.
    function _earlyTrigger() internal view returns (bool) {
        return false;
    }

    /// @dev Phase 1. Dock both proxies (stop quoting), sweep everything back to
    ///      the Manager, then collapse each proxy's period into one trade and
    ///      fold it into cost basis (§8). USDC never leaves the buy proxy except
    ///      by converting to WETH, so `seed - remaining` is exactly what was
    ///      spent; WETH acquired is what was just swept plus anything harvested
    ///      earlier this period. Sell side is the mirror. Dry powder is reduced
    ///      by the USDC that actually converted; the rest returns as balance and
    ///      is re-made-ready by `_replenishPowder`.
    function _collectAndAccount() internal {
        if (buyProxy.strategyHash() != bytes32(0)) buyProxy.dockStrategy();
        if (sellProxy.strategyHash() != bytes32(0)) sellProxy.dockStrategy();

        (uint256 buyUsdc, uint256 buyWeth) = buyProxy.balances();
        (uint256 sellUsdc, uint256 sellWeth) = sellProxy.balances();

        buyProxy.sweep(address(this));
        sellProxy.sweep(address(this));

        // ---- BUY side: USDC spent -> WETH acquired ----
        uint256 usdcSpent = lastBuySeedUsdc > buyUsdc ? lastBuySeedUsdc - buyUsdc : 0;
        uint256 wethAcquired = buyWeth + harvestedWethFromBuy;
        _bookBuys(usdcSpent, wethAcquired);
        if (usdcSpent != 0) {
            dryPowder = dryPowder > usdcSpent ? dryPowder - usdcSpent : 0;
        }

        // ---- SELL side: WETH disposed -> USDC received ----
        uint256 wethSold = lastSellSeedWeth > sellWeth ? lastSellSeedWeth - sellWeth : 0;
        uint256 usdcReceived = sellUsdc + harvestedUsdcFromSell;
        _bookSells(wethSold, usdcReceived);

        // Reset per-period counters.
        lastBuySeedUsdc = 0;
        lastSellSeedWeth = 0;
        harvestedWethFromBuy = 0;
        harvestedUsdcFromSell = 0;
    }

    /// @dev Establish an initial position so `avgEntry` is defined before the
    ///      avg-band trades and placement run (README step 0). Market-buys one
    ///      round's budget of WETH on Uniswap, gated by the same quote check as
    ///      an immediate buy. No-op when there is no powder.
    function _bootstrap(uint256 spot) internal {
        uint256 amountIn = roundBudget();
        if (amountIn == 0) return;
        _buyOnUniswap(amountIn, spot);
    }

    /// @dev Phase 2 (buy leg). Fires only on the 0.5% buffer breach reported by
    ///      Placement — spends `growthPct` of the round budget on Uniswap now,
    ///      rather than parking it all in the ladder. Gated by a QuoterV2
    ///      simulation: executes only if the quoted fill clears the slippage
    ///      threshold vs oracle spot.
    function _maybeImmediateBuy(uint256 spot) internal {
        Placement.Bands memory bands = Placement.compute(anchor, spot, avgEntryWad());
        if (!bands.doGrowthBuy) return;

        uint256 amountIn = roundBudget() * growthPct / BPS;
        if (amountIn > dryPowder) amountIn = dryPowder;
        if (amountIn == 0) return;

        _buyOnUniswap(amountIn, spot);
    }

    /// @dev Phase 2 (sell leg). Fires only on the buffer breach — sells
    ///      `decayPct` of inventory on Uniswap now. Floored by `minSell` so it
    ///      never sells dust, clamped to WETH actually held, and gated by the
    ///      same quote check.
    function _maybeImmediateSell(uint256 spot) internal {
        Placement.Bands memory bands = Placement.compute(anchor, spot, avgEntryWad());
        if (!bands.doDecaySell) return;
        if (inventoryWeth == 0) return;

        uint256 amountIn = inventoryWeth * decayPct / BPS;
        uint256 held = weth.balanceOf(address(this));
        if (amountIn > held) amountIn = held;
        if (amountIn < minSell) return;

        uint256 minOut = amountIn * spot / AVG_SCALE * (BPS - slippageBps) / BPS;
        uint256 quoted = _quote(address(weth), address(usdc), amountIn);
        if (quoted < minOut) return;

        uint256 got = _swapExactIn(address(weth), address(usdc), amountIn, minOut);
        _bookSells(amountIn, got);
    }

    /// @dev Phase 4 (buy leg). Seed the buy proxy with the round budget in USDC
    ///      and ship a fresh single-range strategy over [buyLow, buyHigh]. The
    ///      proxy was docked in phase 1, so the new salt yields distinct bytes
    ///      and a distinct hash (§11, §13).
    function _deployBuyLadder(Placement.Bands memory bands) internal {
        uint256 seed = roundBudget();
        if (seed > dryPowder) seed = dryPowder;
        if (seed == 0) return;

        usdc.safeTransfer(address(buyProxy), seed);
        _shipLadder(buyProxy, bands.buyLowRung, bands.buyHighRung, seed);
        lastBuySeedUsdc = seed;
    }

    /// @dev Phase 4 (sell leg). Seed the sell proxy with all held WETH inventory
    ///      and ship a fresh single-range strategy over [sellLow, sellHigh].
    function _deploySellLadder(Placement.Bands memory bands) internal {
        uint256 seed = weth.balanceOf(address(this));
        if (seed == 0) return;

        weth.safeTransfer(address(sellProxy), seed);
        _shipLadder(sellProxy, bands.sellLowRung, bands.sellHighRung, seed);
        lastSellSeedWeth = seed;
    }

    /*//////////////////////////////////////////////////////////////
                           UNISWAP / SHIP HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Simulate then execute a USDC->WETH buy, booking the fill. Skips
    ///      silently if the quoted output fails the slippage threshold.
    function _buyOnUniswap(uint256 amountIn, uint256 spot) private {
        // expectedWeth = amountIn(USDC,6) * 1e30 / spot(WAD)  -> WETH(18)
        uint256 minOut = amountIn * AVG_SCALE / spot * (BPS - slippageBps) / BPS;
        uint256 quoted = _quote(address(usdc), address(weth), amountIn);
        if (quoted < minOut) return;

        uint256 got = _swapExactIn(address(usdc), address(weth), amountIn, minOut);
        _bookBuys(amountIn, got);
        dryPowder = dryPowder > amountIn ? dryPowder - amountIn : 0;
    }

    /// @dev QuoterV2 simulation. Not view (reverts internally and bubbles the
    ///      result), so it is a plain call here; the pool swap reverts inside
    ///      and persists no state.
    function _quote(address tokenIn, address tokenOut, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        (amountOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                fee: poolFee,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Exact-input single-hop swap on Uniswap v3, recipient = this.
    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        private
        returns (uint256)
    {
        return swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Build and ship a single six-rung range on `proxy`. Salt and sqrt
    ///      bounds come from the proxy so the encoded range and the recorded
    ///      range are derived from the same rungs and cannot disagree (§13).
    function _shipLadder(LadderProxy proxy, uint256 lowRung, uint256 highRung, uint256 amount)
        private
    {
        uint64 salt = proxy.nextSalt();
        uint256 sqrtMin = proxy.sqrtPriceOf(lowRung);
        uint256 sqrtMax = proxy.sqrtPriceOf(highRung);
        bytes memory program = StrategyBuilder.build(address(proxy), sqrtMin, sqrtMax, salt);
        proxy.shipStrategy(aquaApp, program, lowRung, highRung, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            HARVEST  (stubbed)
    //////////////////////////////////////////////////////////////*/

    /// @notice Protective pull of a proxy's ACQUIRED token to the Manager, so
    ///         it can't be converted back at a bad price. Books nothing; only
    ///         tallies for folding at the next rebalance (spec §12).
    /// @dev Pulls only the ACQUIRED token out of the named proxy via
    ///      `pullToken` (buy proxy -> WETH, sell proxy -> USDC), leaving the
    ///      seed side quoting. Books nothing: it only tallies the pulled amount
    ///      into the harvest counter, which `_collectAndAccount` folds into
    ///      cost basis at the next rebalance. Quantity is enough — the price it
    ///      converted at emerges there from `seed - remaining` on the seed side.
    function harvest(bool buySide) external onlyOwner nonReentrant {
        uint256 amount;
        if (buySide) {
            amount = buyProxy.pullToken(address(weth), address(this));
            harvestedWethFromBuy += amount;
        } else {
            amount = sellProxy.pullToken(address(usdc), address(this));
            harvestedUsdcFromSell += amount;
        }
        emit Harvested(buySide, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         EMERGENCY / ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Dock both strategies (stop all quoting) and sweep all assets to
    ///         the Manager. Does not book or take profit — a loss-cutting
    ///         circuit breaker only (§10, §14).
    function emergencyDock() external onlyOwner nonReentrant {
        if (buyProxy.strategyHash() != bytes32(0)) buyProxy.dockStrategy();
        if (sellProxy.strategyHash() != bytes32(0)) sellProxy.dockStrategy();
        buyProxy.sweep(address(this));
        sellProxy.sweep(address(this));
        emit EmergencyDocked();
    }

    function setDests(address _profitDest, address _taxDest) external onlyOwner {
        if (_profitDest == address(0) || _taxDest == address(0)) revert ZeroAddress();
        profitDest = _profitDest;
        taxDest = _taxDest;
        emit DestsUpdated(_profitDest, _taxDest);
    }

    function setSlippage(uint256 _slippageBps) external onlyOwner {
        if (_slippageBps > BPS) revert BadConfig();
        slippageBps = _slippageBps;
        emit SlippageUpdated(_slippageBps);
    }
}
