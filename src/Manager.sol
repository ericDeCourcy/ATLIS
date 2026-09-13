// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {LadderProxy} from "./LadderProxy.sol";
import {Placement} from "./lib/Placement.sol";
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

    function _collectAndAccount() internal pure {
        revert NotImplemented();
    }

    function _bootstrap(uint256 /*spot*/ ) internal pure {
        revert NotImplemented();
    }

    function _maybeImmediateBuy(uint256 /*spot*/ ) internal pure {
        revert NotImplemented();
    }

    function _maybeImmediateSell(uint256 /*spot*/ ) internal pure {
        revert NotImplemented();
    }

    function _deployBuyLadder(Placement.Bands memory /*bands*/ ) internal pure {
        revert NotImplemented();
    }

    function _deploySellLadder(Placement.Bands memory /*bands*/ ) internal pure {
        revert NotImplemented();
    }

    /*//////////////////////////////////////////////////////////////
                            HARVEST  (stubbed)
    //////////////////////////////////////////////////////////////*/

    /// @notice Protective pull of a proxy's ACQUIRED token to the Manager, so
    ///         it can't be converted back at a bad price. Books nothing; only
    ///         tallies for folding at the next rebalance (spec §12).
    /// @dev Requires a single-token pull on LadderProxy — `sweep` moves BOTH
    ///      tokens, which would empty the seed side too. See the note to the
    ///      user; this stub reverts until that method exists.
    function harvest(bool buySide) external onlyOwner nonReentrant {
        buySide; // silence unused warning until implemented
        revert NotImplemented();
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
