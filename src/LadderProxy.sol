// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAqua} from "./interfaces/IAqua.sol";
import {RungMath} from "./lib/RungMath.sol";
import {AquaPriceMath} from "./lib/AquaPriceMath.sol";

/// @title LadderProxy
/// @notice Holds capital and ships a single Aqua strategy covering a range of
///         rungs. Deployed as a plain child contract by the Manager, which is
///         the owner.
///
/// @dev Funds stay in this contract; Aqua only tracks virtual balances against
///      the standing approvals granted in the constructor. A shipped strategy
///      is immutable — changing it means dock() and ship() anew.
contract LadderProxy is Ownable {
    using SafeERC20 for IERC20;

    IAqua public immutable aqua;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;

    /// @notice Price of rung 1000, WAD. Anchors the ladder for this proxy.
    uint256 public immutable anchor;

    /// @notice Which side this proxy is. Fixed at construction.
    ///         BUY  -> seeded with USDC, rungs sit below the ladder anchor
    ///         SELL -> seeded with WETH, rungs sit above it
    /// @dev This constrains only what can be PUT IN. Positions are ranged
    ///      liquidity and quote both directions, so a buy proxy will come to
    ///      hold WETH as price moves through its band. That is expected, and
    ///      sweep() removes both tokens.
    bool public immutable isBuySide;

    /// @notice Hash of the live strategy. Zero when nothing is shipped.
    bytes32 public strategyHash;

    /// @notice The app (router) the live strategy was shipped to.
    address public app;

    /// @notice Rung bounds of the live strategy.
    uint256 public lowRung;
    uint256 public highRung;

    /// @notice Aqua sqrt-price encodings of the rung bounds.
    uint256 public sqrtPriceLow;
    uint256 public sqrtPriceHigh;

    event Shipped(address indexed app, bytes32 indexed strategyHash, uint256 usdcAmount, uint256 wethAmount);
    event Bounds(uint256 lowRung, uint256 highRung, uint256 sqrtPriceLow, uint256 sqrtPriceHigh);
    event Docked(address indexed app, bytes32 indexed strategyHash);
    event ToppedUp(address indexed token, uint256 amount, uint256 newDeclaredBalance);

    error AlreadyShipped();
    error NothingShipped();
    error ZeroAddress();
    error NoLiquidity();
    error BadRungOrder();
    error ZeroAnchor();
    error UnknownToken();
    error WrongSide();
    error ZeroAmount();

    constructor(
        address _aqua,
        address _usdc,
        address _weth,
        uint256 _anchor,
        bool _isBuySide,
        address _owner
    ) Ownable(_owner) {
        if (_aqua == address(0) || _usdc == address(0) || _weth == address(0)) {
            revert ZeroAddress();
        }
        if (_anchor == 0) revert ZeroAnchor();

        anchor = _anchor;
        isBuySide = _isBuySide;
        aqua = IAqua(_aqua);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);

        // Standing approvals. This allowance — not a signature — is what lets
        // Aqua move funds out of this contract when a swap fills.
        IERC20(_usdc).forceApprove(_aqua, type(uint256).max);
        IERC20(_weth).forceApprove(_aqua, type(uint256).max);
    }

    /// @notice Ships a strategy covering [`_lowRung`, `_highRung`], allocating
    ///         this contract's balances to it.
    /// @param _app The router that will execute `strategy`.
    /// @param strategy Pre-encoded SwapVM program covering the rung range.
    /// @param _lowRung Lower rung bound, inclusive.
    /// @param _highRung Upper rung bound, inclusive. Must exceed `_lowRung`.
    /// @param amount Virtual liquidity of the SEED token to allocate. The
    ///        opposite token is always allocated zero — a proxy is single-sided
    ///        on the way in, even though fills may leave it holding both.
    /// @dev The declared amount sets the DEPTH OF THE CURVE, not a cap
    ///      (XYCConcentrateSwap derives liquidity from it). Ship exactly what
    ///      the proxy holds, or it quotes prices its inventory cannot honour.
    ///
    ///      The sqrt prices are derived here and recorded, but are NOT spliced
    ///      into `strategy` — the caller is responsible for encoding bounds
    ///      that match. Compare the emitted Bounds event against the program
    ///      to confirm they agree.
    function shipStrategy(
        address _app,
        bytes calldata strategy,
        uint256 _lowRung,
        uint256 _highRung,
        uint256 amount
    ) external onlyOwner returns (bytes32) {
        if (strategyHash != bytes32(0)) revert AlreadyShipped();
        if (_app == address(0)) revert ZeroAddress();
        if (amount == 0) revert NoLiquidity();
        if (_lowRung >= _highRung) revert BadRungOrder();

        // Single-sided allocation: seed token gets `amount`, the other zero.
        (uint256 usdcAmount, uint256 wethAmount) =
            isBuySide ? (amount, uint256(0)) : (uint256(0), amount);

        uint256 sLow = sqrtPriceOf(_lowRung);
        uint256 sHigh = sqrtPriceOf(_highRung);

        lowRung = _lowRung;
        highRung = _highRung;
        sqrtPriceLow = sLow;
        sqrtPriceHigh = sHigh;
        emit Bounds(_lowRung, _highRung, sLow, sHigh);

        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        amounts[0] = usdcAmount;
        amounts[1] = wethAmount;

        bytes32 h = aqua.ship(_app, strategy, tokens, amounts);

        app = _app;
        strategyHash = h;

        emit Shipped(_app, h, usdcAmount, wethAmount);
        return h;
    }

    /*//////////////////////////////////////////////////////////////
                                 DOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice Docks the live strategy, zeroing its declared balances so it
    ///         stops quoting. Leaves no unfillable position behind.
    /// @dev Aqua requires the token array to list every token the strategy was
    ///      shipped with (balance.tokensCount == tokens.length), so both are
    ///      always passed — matching shipStrategy, which always ships both.
    ///
    ///      Docking is TERMINAL for these strategy bytes. Aqua sets tokensCount
    ///      to _DOCKED, and ship() only accepts tokensCount == 0, so the same
    ///      program can never be shipped again by this maker. Re-shipping
    ///      requires different bytes — vary the Salt instruction.
    function dockStrategy() external onlyOwner {
        bytes32 h = strategyHash;
        if (h == bytes32(0)) revert NothingShipped();

        address _app = app;

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        aqua.dock(_app, h, tokens);

        strategyHash = bytes32(0);
        app = address(0);

        emit Docked(_app, h);
    }

    /*//////////////////////////////////////////////////////////////
                                TOP UP
    //////////////////////////////////////////////////////////////*/

    /// @notice Raises the live strategy's declared balance for `token` by
    ///         `amount`, without docking and re-shipping.
    /// @dev Aqua's push transfers `amount` from msg.sender to maker. Both are
    ///      this contract, so the transfer is a self-transfer moving nothing;
    ///      only the declared balance changes. Relies on the standing approval
    ///      granted in the constructor.
    ///
    ///      The declared balance drives computeLiquidity, so this DEEPENS THE
    ///      CURVE rather than merely raising a cap. Push only what the proxy
    ///      actually holds, or it will quote prices its inventory cannot honour
    ///      and fills will revert at Aqua.pull.
    ///
    ///      push() only adds. There is no maker-callable decrement; reducing a
    ///      declared balance requires docking.
    function topUp(address token, uint256 amount) external onlyOwner {
        if (strategyHash == bytes32(0)) revert NothingShipped();
        if (token != address(usdc) && token != address(weth)) revert UnknownToken();
        // Only the seed token may be added. Tokens acquired through fills are
        // swept out at rebalance, never topped up into the declared balance.
        if (token != address(seedToken())) revert WrongSide();
        if (amount == 0) revert ZeroAmount();

        aqua.push(address(this), app, strategyHash, token, amount);

        (uint248 declared,) = aqua.rawBalances(address(this), app, strategyHash, token);
        emit ToppedUp(token, amount, declared);
    }

    /// @notice Declared (virtual) balance Aqua holds for the live strategy.
    /// @dev Distinct from balances(), which reports real tokens held. The curve
    ///      is priced off THIS number, not the real one.
    function declaredBalances() external view returns (uint256 usdcDeclared, uint256 wethDeclared) {
        bytes32 h = strategyHash;
        if (h == bytes32(0)) return (0, 0);

        (uint248 u,) = aqua.rawBalances(address(this), app, h, address(usdc));
        (uint248 w,) = aqua.rawBalances(address(this), app, h, address(weth));
        return (u, w);
    }

    /// @notice Transfers both token balances to `to`. Does not dock.
    /// @dev The strategy stays live after a sweep. It quotes nothing while the
    ///      contract is empty, but quotes again if tokens are transferred back.
    function sweep(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        uint256 u = usdc.balanceOf(address(this));
        uint256 w = weth.balanceOf(address(this));

        if (u != 0) usdc.safeTransfer(to, u);
        if (w != 0) weth.safeTransfer(to, w);
    }

    /// @notice The only token that may be allocated or topped up here.
    function seedToken() public view returns (IERC20) {
        return isBuySide ? usdc : weth;
    }

    /// @notice Aqua sqrt-price encoding of a rung, via the ladder anchor.
    function sqrtPriceOf(uint256 rung) public view returns (uint256) {
        return AquaPriceMath.toSqrtPriceUsdcWeth(RungMath.priceAt(anchor, rung));
    }

    /// @notice Current token balances held by this proxy.
    function balances() external view returns (uint256 usdcBalance, uint256 wethBalance) {
        return (usdc.balanceOf(address(this)), weth.balanceOf(address(this)));
    }
}
