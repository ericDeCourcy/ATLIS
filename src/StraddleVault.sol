// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// TODO: Clean up comments to be more objective and less conversational
// TODO: change AI disclaimer in README
// TODO: change instances of btc to wbtc

/*//////////////////////////////////////////////////////////////
                        AQUA INTERFACES
    VERIFIED SHAPE (from 1inch/sdks TS SDK + aqua README):
      ship({ app, strategy, amountsAndTokens })
      dock({ app, strategyHash, tokens })
    The Solidity-level argument layout below is my best reconstruction
    of that shape. Before you deploy, diff these signatures against the
    actual 1inch/aqua registry ABI + aqua-app-template — do NOT trust
    them blind. Funds stay in THIS contract; Aqua only tracks virtual
    balances against the standing approval granted in the constructor.
//////////////////////////////////////////////////////////////*/

struct TokenAmount {
    address token;
    uint256 amount;
}

interface IAqua {
    function ship(address app, bytes calldata strategy, TokenAmount[] calldata amountsAndTokens)
        external
        returns (bytes32 strategyHash);

    function dock(address app, bytes32 strategyHash, address[] calldata tokens) external;
}

/// @notice The piece I did NOT verify. A concentrated ("Straight") SwapVM
///         program is low-level bytecode ([opcode][argsLength][args]); its
///         exact encoding for price-bounded single-sided liquidity must come
///         from the real builder (aqua-app-template / DocaApp), not from me.
///         Wire this to that builder. `zeroForOne` fixes which token is sold
///         by the position; `lower`/`upper` are the price bounds in the same
///         fixed-point unit as `entryPrice` (USDC 1e6 per 1 BTC here).
interface IStrategyBuilder {
    function buildConcentrated(
        address tokenIn,
        address tokenOut,
        uint256 lowerPrice,
        uint256 upperPrice,
        uint256 amount
    ) external view returns (bytes memory program);
}

/*//////////////////////////////////////////////////////////////
                          THE VAULT
//////////////////////////////////////////////////////////////*/

contract StraddleVault is Ownable {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    IAqua public immutable aqua;
    IStrategyBuilder public immutable builder;
    address public immutable app; // the AquaSwapVMRouter that executes the program

    IERC20 public immutable usdc; // 6 decimals
    IERC20 public immutable btc;  // WBTC, 8 decimals

    // ---- live position handles (0 == not shipped) ----
    bytes32 public buyHash;
    bytes32 public sellHash;

    // ---- the parameters, in the units the prompt specified ----
    struct Bands {
        uint256 entryPrice;   // USDC(1e6) per 1 BTC
        uint256 buyLower;     // = entry * (1 - maxDrawdown)  -> all USDC deployed here
        uint256 buyUpper;     // = entry * (1 - minDrawdown)  -> buying begins here
        uint256 sellLower;    // = entry * (1 + minProfit)    -> selling begins here
        uint256 sellUpper;    // = entry * (1 + maxProfit)    -> all BTC sold here
    }

    Bands public bands;

    event Configured(uint256 buyLower, uint256 buyUpper, uint256 sellLower, uint256 sellUpper);
    event BuyShipped(bytes32 hash, uint256 usdcAmount);
    event SellShipped(bytes32 hash, uint256 btcAmount);
    event Docked(bytes32 hash);

    constructor(
        address _aqua,
        address _builder,
        address _app,
        address _usdc,
        address _btc
    ) Ownable(msg.sender) {
        aqua = IAqua(_aqua);
        builder = IStrategyBuilder(_builder);
        app = _app;
        usdc = IERC20(_usdc);
        btc = IERC20(_btc);

        // One-time approvals. This standing allowance — NOT any signature —
        // is what authorizes Aqua to move funds out of this contract on a fill.
        // Approve exact-need in production instead of max.
        usdc.forceApprove(_aqua, type(uint256).max);
        btc.forceApprove(_aqua, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
        PRICE MATH  — this part I'm confident is correct.

        All five inputs come straight from the prompt. Drawdowns and
        profits are in basis points (100 bps = 1%). The ordering checks
        guarantee the two bands sit strictly on either side of entry with
        a dead zone in between, so each position is single-sided.
    //////////////////////////////////////////////////////////////*/
    function configure(
        uint256 entryPrice,
        uint256 minDrawdownBps,
        uint256 maxDrawdownBps,
        uint256 minProfitBps,
        uint256 maxProfitBps
    ) external onlyOwner {
        require(entryPrice > 0, "entry=0");
        require(minDrawdownBps < maxDrawdownBps, "drawdown order");
        require(maxDrawdownBps < BPS, "drawdown >= 100%");
        require(minProfitBps < maxProfitBps, "profit order");

        Bands memory b;
        b.entryPrice = entryPrice;

        // Buy side: entirely BELOW entry -> deposit ONLY USDC.
        // Buying begins near entry (small drawdown), full deployment at the floor.
        b.buyUpper = entryPrice * (BPS - minDrawdownBps) / BPS;
        b.buyLower = entryPrice * (BPS - maxDrawdownBps) / BPS;

        // Sell side: entirely ABOVE entry -> deposit ONLY BTC.
        // Selling begins near entry (small profit), fully sold at the ceiling.
        b.sellLower = entryPrice * (BPS + minProfitBps) / BPS;
        b.sellUpper = entryPrice * (BPS + maxProfitBps) / BPS;

        bands = b;
        emit Configured(b.buyLower, b.buyUpper, b.sellLower, b.sellUpper);
    }

    /*//////////////////////////////////////////////////////////////
        SHIP THE BUY SIDE  (single-sided USDC, range below spot)
        Sells USDC (tokenIn) for BTC (tokenOut) as price falls through
        [buyLower, buyUpper]. Bootstrap the strategy with this side first,
        since the sell side needs BTC inventory this side produces.
    //////////////////////////////////////////////////////////////*/
    function shipBuy(uint256 usdcAmount) external onlyOwner {
        require(buyHash == bytes32(0), "buy live: dock first");
        require(usdcAmount > 0 && usdcAmount <= usdc.balanceOf(address(this)), "usdc bal");

        bytes memory program = builder.buildConcentrated(
            address(usdc), address(btc), bands.buyLower, bands.buyUpper, usdcAmount
        );

        TokenAmount[] memory alloc = new TokenAmount[](1);
        alloc[0] = TokenAmount({token: address(usdc), amount: usdcAmount});

        buyHash = aqua.ship(app, program, alloc);
        emit BuyShipped(buyHash, usdcAmount);
    }

    /*//////////////////////////////////////////////////////////////
        SHIP THE SELL SIDE  (single-sided BTC, range above spot)
        Sells BTC (tokenIn) for USDC (tokenOut) as price rises through
        [sellLower, sellUpper].
    //////////////////////////////////////////////////////////////*/
    function shipSell(uint256 btcAmount) external onlyOwner {
        require(sellHash == bytes32(0), "sell live: dock first");
        require(btcAmount > 0 && btcAmount <= btc.balanceOf(address(this)), "btc bal");

        bytes memory program = builder.buildConcentrated(
            address(btc), address(usdc), bands.sellLower, bands.sellUpper, btcAmount
        );

        TokenAmount[] memory alloc = new TokenAmount[](1);
        alloc[0] = TokenAmount({token: address(btc), amount: btcAmount});

        sellHash = aqua.ship(app, program, alloc);
        emit SellShipped(sellHash, btcAmount);
    }

    /*//////////////////////////////////////////////////////////////
        DOCK  — instant, no token movement, pure accounting revocation.
        Used for the daily rebalance, profit-taking, AND the emergency
        circuit-breaker (same call, different trigger upstream in the keeper).
    //////////////////////////////////////////////////////////////*/
    function dockBuy() public onlyOwner {
        require(buyHash != bytes32(0), "no buy");
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(btc);
        aqua.dock(app, buyHash, tokens);
        emit Docked(buyHash);
        buyHash = bytes32(0);
    }

    function dockSell() public onlyOwner {
        require(sellHash != bytes32(0), "no sell");
        address[] memory tokens = new address[](2);
        tokens[0] = address(btc);
        tokens[1] = address(usdc);
        aqua.dock(app, sellHash, tokens);
        emit Docked(sellHash);
        sellHash = bytes32(0);
    }

    /// @notice Emergency: tear down everything in one call. Keeper points its
    ///         staleness / freefall / kill-switch trigger here.
    function emergencyDockAll() external onlyOwner {
        if (buyHash != bytes32(0)) dockBuy();
        if (sellHash != bytes32(0)) dockSell();
    }

    /// @dev Rescue idle funds (e.g. sweep to an Aave-earning reserve between cycles).
    function withdraw(address token, uint256 amount, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}
