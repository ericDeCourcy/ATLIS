// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LadderProxy} from "../src/LadderProxy.sol";
import {SaltLib} from "../src/lib/SaltLib.sol";
import {IAqua} from "../src/interfaces/IAqua.sol";
import {RungMath} from "../src/lib/RungMath.sol";
import {AquaPriceMath} from "../src/lib/AquaPriceMath.sol";

contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev Mirrors 1inch/aqua src/Aqua.sol accounting, including the terminal
///      _DOCKED state, so tests cannot pass against a looser mock than reality.
contract MockAqua is IAqua {
    uint8 private constant _DOCKED = 0xff;

    struct Balance {
        uint248 amount;
        uint8 tokensCount;
    }

    mapping(address => mapping(address => mapping(bytes32 => mapping(address => Balance)))) private _balances;

    address public lastApp;
    bytes public lastStrategy;
    address[] public lastTokens;
    uint256[] public lastAmounts;
    uint256 public shipCount;
    uint256 public dockCount;
    uint256 public pushCount;

    error StrategiesMustBeImmutable();
    error DockingShouldCloseAllTokens();
    error PushToNonActiveStrategyPrevented();

    function ship(
        address app,
        bytes calldata strategy,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external returns (bytes32 strategyHash) {
        strategyHash = keccak256(strategy);
        uint8 tokensCount = uint8(tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            Balance storage b = _balances[msg.sender][app][strategyHash][tokens[i]];
            // ship() only accepts a never-used slot: 0, not _DOCKED.
            if (b.tokensCount != 0) revert StrategiesMustBeImmutable();
            b.amount = uint248(amounts[i]);
            b.tokensCount = tokensCount;
        }

        lastApp = app;
        lastStrategy = strategy;
        lastTokens = tokens;
        lastAmounts = amounts;
        shipCount++;
    }

    function dock(address app, bytes32 strategyHash, address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            Balance storage b = _balances[msg.sender][app][strategyHash][tokens[i]];
            if (b.tokensCount != tokens.length) revert DockingShouldCloseAllTokens();
            b.amount = 0;
            b.tokensCount = _DOCKED;
        }
        dockCount++;
    }

    function push(address maker, address app, bytes32 strategyHash, address token, uint256 amount) external {
        Balance storage b = _balances[maker][app][strategyHash][token];
        if (b.tokensCount == 0 || b.tokensCount == _DOCKED) revert PushToNonActiveStrategyPrevented();
        b.amount += uint248(amount);
        IERC20(token).transferFrom(msg.sender, maker, amount);
        pushCount++;
    }

    function rawBalances(address maker, address app, bytes32 strategyHash, address token)
        external
        view
        returns (uint248, uint8)
    {
        Balance storage b = _balances[maker][app][strategyHash][token];
        return (b.amount, b.tokensCount);
    }

    function tokensLength() external view returns (uint256) {
        return lastTokens.length;
    }
}

contract LadderProxyTest is Test {
    MockAqua aqua;
    MockToken usdc;
    MockToken weth;
    LadderProxy proxy;      // buy side, seeded with USDC
    LadderProxy sellProxy;  // sell side, seeded with WETH

    address manager = address(0xA4);
    address stranger = address(0xBEEF);
    address app = address(0xA99);

    bytes constant STRATEGY = hex"211426ffc7d378e8e49be2c483295a3e3e511f96a4681c";

    uint256 constant ANCHOR = 3000e18;         // rung 1000 = 3000 USDC/WETH
    uint256 constant BASE = RungMath.BASE_RUNG;
    uint256 constant LOW = BASE - 6;           // buy-side band: rl-6 .. rl
    uint256 constant HIGH = BASE;

    function setUp() public {
        aqua = new MockAqua();
        usdc = new MockToken("USD Coin", "USDC", 6);
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        proxy = new LadderProxy(address(aqua), address(usdc), address(weth), ANCHOR, true, manager);
        sellProxy = new LadderProxy(address(aqua), address(usdc), address(weth), ANCHOR, false, manager);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_constructorStoresImmutables() public view {
        assertEq(address(proxy.aqua()), address(aqua));
        assertEq(address(proxy.usdc()), address(usdc));
        assertEq(address(proxy.weth()), address(weth));
    }

    function test_ownerIsManager() public view {
        assertEq(proxy.owner(), manager);
    }

    /// @dev The standing approval, not a signature, is what authorises Aqua.
    function test_constructorApprovesAqua() public view {
        assertEq(usdc.allowance(address(proxy), address(aqua)), type(uint256).max);
        assertEq(weth.allowance(address(proxy), address(aqua)), type(uint256).max);
    }

    function test_constructorRevertsOnZeroAqua() public {
        vm.expectRevert(LadderProxy.ZeroAddress.selector);
        new LadderProxy(address(0), address(usdc), address(weth), ANCHOR, true, manager);
    }

    function test_constructorRevertsOnZeroToken() public {
        vm.expectRevert(LadderProxy.ZeroAddress.selector);
        new LadderProxy(address(aqua), address(0), address(weth), ANCHOR, true, manager);
    }

    function test_nothingShippedInitially() public view {
        assertEq(proxy.strategyHash(), bytes32(0));
        assertEq(proxy.app(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 SHIP
    //////////////////////////////////////////////////////////////*/

    function test_shipStrategy_storesHashAndApp() public {
        vm.prank(manager);
        bytes32 h = proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        assertEq(proxy.strategyHash(), h);
        assertEq(proxy.app(), app);
        assertTrue(h != bytes32(0));
    }

    /// @dev Both tokens are always registered with Aqua as parallel arrays,
    ///      USDC first — but only the seed token gets a nonzero amount.
    function test_shipStrategy_forwardsParallelArrays() public {
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        assertEq(aqua.tokensLength(), 2);
        assertEq(aqua.lastTokens(0), address(usdc));
        assertEq(aqua.lastTokens(1), address(weth));
        assertEq(aqua.lastAmounts(0), 1000e6);
        assertEq(aqua.lastAmounts(1), 0);
    }

    function test_shipStrategy_forwardsStrategyBytesVerbatim() public {
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        assertEq(aqua.lastStrategy(), STRATEGY);
        assertEq(aqua.lastApp(), app);
    }

    function test_shipStrategy_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit LadderProxy.Shipped(app, bytes32(0), 1000e6, 0);
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
    }

    /// @dev Single-sided allocation is the normal case for a seeded proxy.
    function test_shipStrategy_singleSidedUsdc() public {
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        assertEq(aqua.lastAmounts(1), 0);
    }

    /// @dev A sell proxy allocates WETH and zero USDC — the mirror case.
    function test_shipStrategy_sellSideAllocatesWeth() public {
        vm.prank(manager);
        sellProxy.shipStrategy(app, STRATEGY, LOW, HIGH, 2e18);
        assertEq(aqua.lastAmounts(0), 0);
        assertEq(aqua.lastAmounts(1), 2e18);
    }

    /// @dev Aqua does not check balances at ship time, so allocating more than
    ///      held is allowed. Such a strategy reverts on fill instead.
    function test_shipStrategy_allowsOverAllocation() public {
        assertEq(usdc.balanceOf(address(proxy)), 0);
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1_000_000e6);
        assertEq(aqua.shipCount(), 1);
    }

    function test_shipStrategy_revertsIfAlreadyShipped() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        vm.expectRevert(LadderProxy.AlreadyShipped.selector);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        vm.stopPrank();
    }

    function test_shipStrategy_revertsOnZeroApp() public {
        vm.prank(manager);
        vm.expectRevert(LadderProxy.ZeroAddress.selector);
        proxy.shipStrategy(address(0), STRATEGY, LOW, HIGH, 1000e6);
    }

    function test_shipStrategy_revertsOnNoLiquidity() public {
        vm.prank(manager);
        vm.expectRevert(LadderProxy.NoLiquidity.selector);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 0);
    }

    function test_shipStrategy_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
    }

    /*//////////////////////////////////////////////////////////////
                                SWEEP
    //////////////////////////////////////////////////////////////*/

    function test_sweep_movesBothTokens() public {
        usdc.mint(address(proxy), 500e6);
        weth.mint(address(proxy), 3e18);

        vm.prank(manager);
        proxy.sweep(manager);

        assertEq(usdc.balanceOf(manager), 500e6);
        assertEq(weth.balanceOf(manager), 3e18);
        assertEq(usdc.balanceOf(address(proxy)), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
    }

    /// @dev A proxy seeded with one asset may hold both after fills.
    function test_sweep_handlesSingleAsset() public {
        usdc.mint(address(proxy), 500e6);

        vm.prank(manager);
        proxy.sweep(manager);

        assertEq(usdc.balanceOf(manager), 500e6);
        assertEq(weth.balanceOf(manager), 0);
    }

    function test_sweep_emptyIsNoop() public {
        vm.prank(manager);
        proxy.sweep(manager);
        assertEq(usdc.balanceOf(manager), 0);
    }

    /// @dev Sweeping does not dock: the strategy stays live and reusable.
    function test_sweep_leavesStrategyLive() public {
        usdc.mint(address(proxy), 500e6);
        vm.startPrank(manager);
        bytes32 h = proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 500e6);
        proxy.sweep(manager);
        vm.stopPrank();

        assertEq(proxy.strategyHash(), h);
        assertEq(proxy.app(), app);
    }

    /// @dev Refunding a swept proxy makes it quote again — the reuse premise.
    function test_sweep_thenRefund() public {
        usdc.mint(address(proxy), 500e6);
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 500e6);
        proxy.sweep(manager);
        vm.stopPrank();

        usdc.mint(address(proxy), 700e6);
        (uint256 u,) = proxy.balances();
        assertEq(u, 700e6);
        assertEq(usdc.allowance(address(proxy), address(aqua)), type(uint256).max);
    }

    function test_sweep_revertsOnZeroAddress() public {
        vm.prank(manager);
        vm.expectRevert(LadderProxy.ZeroAddress.selector);
        proxy.sweep(address(0));
    }

    function test_sweep_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        proxy.sweep(stranger);
    }

    /*//////////////////////////////////////////////////////////////
                               BALANCES
    //////////////////////////////////////////////////////////////*/

    function test_balances() public {
        usdc.mint(address(proxy), 123e6);
        weth.mint(address(proxy), 4e18);

        (uint256 u, uint256 w) = proxy.balances();
        assertEq(u, 123e6);
        assertEq(w, 4e18);
    }

    function testFuzz_sweepMovesExactBalance(uint128 u, uint128 w) public {
        usdc.mint(address(proxy), u);
        weth.mint(address(proxy), w);

        vm.prank(manager);
        proxy.sweep(manager);

        assertEq(usdc.balanceOf(manager), u);
        assertEq(weth.balanceOf(manager), w);
    }

    /*//////////////////////////////////////////////////////////////
                          RUNG -> AQUA PRICE
    //////////////////////////////////////////////////////////////*/

    function test_anchorStored() public view {
        assertEq(proxy.anchor(), ANCHOR);
    }

    function test_constructorRevertsOnZeroAnchor() public {
        vm.expectRevert(LadderProxy.ZeroAnchor.selector);
        new LadderProxy(address(aqua), address(usdc), address(weth), 0, true, manager);
    }

    /// @dev Anchor rung encodes to the known 3000 USDC/WETH sqrt price.
    function test_sqrtPriceOf_anchorRung() public view {
        assertEq(proxy.sqrtPriceOf(BASE), 0x31d0a8d8f974);
    }

    function test_sqrtPriceOf_matchesLibraries() public view {
        uint256 expected = AquaPriceMath.toSqrtPriceUsdcWeth(RungMath.priceAt(ANCHOR, BASE - 3));
        assertEq(proxy.sqrtPriceOf(BASE - 3), expected);
    }

    /// @dev Encoding must preserve rung ordering.
    function test_sqrtPriceOf_monotonic() public view {
        uint256 prev;
        for (uint256 n = BASE - 6; n <= BASE + 6; n++) {
            uint256 p = proxy.sqrtPriceOf(n);
            if (prev != 0) assertGt(p, prev);
            prev = p;
        }
    }

    function test_shipStrategy_storesRungsAndPrices() public {
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        assertEq(proxy.lowRung(), LOW);
        assertEq(proxy.highRung(), HIGH);
        assertEq(proxy.sqrtPriceLow(), proxy.sqrtPriceOf(LOW));
        assertEq(proxy.sqrtPriceHigh(), proxy.sqrtPriceOf(HIGH));
        assertLt(proxy.sqrtPriceLow(), proxy.sqrtPriceHigh());
    }

    function test_shipStrategy_emitsBounds() public {
        uint256 sLow = proxy.sqrtPriceOf(LOW);
        uint256 sHigh = proxy.sqrtPriceOf(HIGH);

        vm.expectEmit(false, false, false, true);
        emit LadderProxy.Bounds(LOW, HIGH, sLow, sHigh);
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
    }

    function test_shipStrategy_revertsOnInvertedRungs() public {
        vm.prank(manager);
        vm.expectRevert(LadderProxy.BadRungOrder.selector);
        proxy.shipStrategy(app, STRATEGY, HIGH, LOW, 1000e6);
    }

    function test_shipStrategy_revertsOnEqualRungs() public {
        vm.prank(manager);
        vm.expectRevert(LadderProxy.BadRungOrder.selector);
        proxy.shipStrategy(app, STRATEGY, BASE, BASE, 1000e6);
    }

    /// @dev A 6-rung band spans ~14% in price terms (0.975^6).
    function test_sixRungBandWidth() public view {
        uint256 lo = RungMath.priceAt(ANCHOR, BASE - 6);
        uint256 hi = RungMath.priceAt(ANCHOR, BASE);
        assertApproxEqRel(lo, (hi * 859) / 1000, 1e15);
    }

    function testFuzz_sqrtPriceOf_monotonic(uint16 a) public view {
        uint256 n = bound(a, BASE - 50, BASE + 49);
        assertGt(proxy.sqrtPriceOf(n + 1), proxy.sqrtPriceOf(n));
    }

    /*//////////////////////////////////////////////////////////////
                                 DOCK
    //////////////////////////////////////////////////////////////*/

    function test_dock_clearsState() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.dockStrategy();
        vm.stopPrank();

        assertEq(proxy.strategyHash(), bytes32(0));
        assertEq(proxy.app(), address(0));
        assertEq(aqua.dockCount(), 1);
    }

    /// @dev Docking must zero the declared balance so the position stops quoting.
    function test_dock_zeroesDeclaredBalance() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        (uint256 uBefore,) = proxy.declaredBalances();
        assertEq(uBefore, 1000e6);

        proxy.dockStrategy();
        vm.stopPrank();

        (uint256 uAfter, uint256 wAfter) = proxy.declaredBalances();
        assertEq(uAfter, 0);
        assertEq(wAfter, 0);
    }

    function test_dock_emitsEvent() public {
        vm.startPrank(manager);
        bytes32 h = proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        vm.expectEmit(true, true, false, false);
        emit LadderProxy.Docked(app, h);
        proxy.dockStrategy();
        vm.stopPrank();
    }

    function test_dock_revertsIfNothingShipped() public {
        vm.prank(manager);
        vm.expectRevert(LadderProxy.NothingShipped.selector);
        proxy.dockStrategy();
    }

    function test_dock_revertsIfAlreadyDocked() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.dockStrategy();
        vm.expectRevert(LadderProxy.NothingShipped.selector);
        proxy.dockStrategy();
        vm.stopPrank();
    }

    function test_dock_onlyOwner() public {
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        proxy.dockStrategy();
    }

    /// @dev Docking is TERMINAL for these bytes: Aqua sets tokensCount to
    ///      _DOCKED and ship() only accepts 0. Re-shipping needs a new salt.
    function test_dock_sameBytesCannotBeReshipped() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.dockStrategy();

        vm.expectRevert(MockAqua.StrategiesMustBeImmutable.selector);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        vm.stopPrank();
    }

    /// @dev Different bytes hash differently, so a re-ship with a new salt works.
    function test_dock_thenReshipWithDifferentBytes() public {
        bytes memory other = hex"211426ffc7d378e8e49be2c483295a3e3e511f96a4682c";

        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.dockStrategy();
        bytes32 h2 = proxy.shipStrategy(app, other, LOW, HIGH, 1000e6);
        vm.stopPrank();

        assertEq(proxy.strategyHash(), h2);
        assertEq(aqua.shipCount(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                                TOP UP
    //////////////////////////////////////////////////////////////*/

    /// @dev Self-push: declared balance rises, no tokens actually move.
    function test_topUp_raisesDeclaredBalance() public {
        usdc.mint(address(proxy), 1500e6);

        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.topUp(address(usdc), 500e6);
        vm.stopPrank();

        (uint256 declared,) = proxy.declaredBalances();
        assertEq(declared, 1500e6);
    }

    function test_topUp_doesNotMoveTokens() public {
        usdc.mint(address(proxy), 1500e6);

        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.topUp(address(usdc), 500e6);
        vm.stopPrank();

        (uint256 real,) = proxy.balances();
        assertEq(real, 1500e6);
    }

    function test_topUp_sellSideWeth() public {
        weth.mint(address(sellProxy), 5e18);

        vm.startPrank(manager);
        sellProxy.shipStrategy(app, STRATEGY, LOW, HIGH, 2e18);
        sellProxy.topUp(address(weth), 3e18);
        vm.stopPrank();

        (, uint256 declared) = sellProxy.declaredBalances();
        assertEq(declared, 5e18);
    }

    function test_topUp_accumulates() public {
        usdc.mint(address(proxy), 3000e6);

        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.topUp(address(usdc), 500e6);
        proxy.topUp(address(usdc), 500e6);
        vm.stopPrank();

        (uint256 declared,) = proxy.declaredBalances();
        assertEq(declared, 2000e6);
        assertEq(aqua.pushCount(), 2);
    }

    function test_topUp_revertsIfNothingShipped() public {
        vm.prank(manager);
        vm.expectRevert(LadderProxy.NothingShipped.selector);
        proxy.topUp(address(usdc), 500e6);
    }

    /// @dev Aqua rejects a push to a docked strategy; the proxy's own guard
    ///      catches it first since dockStrategy clears strategyHash.
    function test_topUp_revertsAfterDock() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.dockStrategy();
        vm.expectRevert(LadderProxy.NothingShipped.selector);
        proxy.topUp(address(usdc), 500e6);
        vm.stopPrank();
    }

    function test_topUp_revertsOnUnknownToken() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        vm.expectRevert(LadderProxy.UnknownToken.selector);
        proxy.topUp(address(0xDEAD), 500e6);
        vm.stopPrank();
    }

    function test_topUp_revertsOnZeroAmount() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        vm.expectRevert(LadderProxy.ZeroAmount.selector);
        proxy.topUp(address(usdc), 0);
        vm.stopPrank();
    }

    function test_topUp_onlyOwner() public {
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        proxy.topUp(address(usdc), 500e6);
    }

    /// @dev topUp avoids the dock-and-reship cycle entirely: one push, no new
    ///      strategy, same hash still live.
    function test_topUp_avoidsReship() public {
        usdc.mint(address(proxy), 2000e6);

        vm.startPrank(manager);
        bytes32 h = proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.topUp(address(usdc), 1000e6);
        vm.stopPrank();

        assertEq(proxy.strategyHash(), h);
        assertEq(aqua.shipCount(), 1);
        assertEq(aqua.dockCount(), 0);
    }

    function testFuzz_topUp(uint128 initial, uint128 extra) public {
        vm.assume(initial > 0 && extra > 0);
        usdc.mint(address(proxy), uint256(initial) + uint256(extra));

        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, initial);
        proxy.topUp(address(usdc), extra);
        vm.stopPrank();

        (uint256 declared,) = proxy.declaredBalances();
        assertEq(declared, uint256(initial) + uint256(extra));
    }

    /*//////////////////////////////////////////////////////////////
                        DECLARED VS REAL BALANCE
    //////////////////////////////////////////////////////////////*/

    function test_declaredBalances_zeroBeforeShip() public view {
        (uint256 u, uint256 w) = proxy.declaredBalances();
        assertEq(u, 0);
        assertEq(w, 0);
    }

    /// @dev The curve prices off the DECLARED balance, so sweeping without
    ///      docking leaves a position quoting depth it cannot honour.
    function test_sweepWithoutDock_leavesDeclaredBalanceStale() public {
        usdc.mint(address(proxy), 1000e6);

        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.sweep(manager);
        vm.stopPrank();

        (uint256 real,) = proxy.balances();
        (uint256 declared,) = proxy.declaredBalances();

        assertEq(real, 0);
        assertEq(declared, 1000e6); // stale: still quoting
    }

    /// @dev Docking before sweeping leaves nothing behind.
    function test_dockThenSweep_isClean() public {
        usdc.mint(address(proxy), 1000e6);

        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.dockStrategy();
        proxy.sweep(manager);
        vm.stopPrank();

        (uint256 real,) = proxy.balances();
        (uint256 declared,) = proxy.declaredBalances();

        assertEq(real, 0);
        assertEq(declared, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            SIDE CONSTRAINT
    //////////////////////////////////////////////////////////////*/

    function test_side_buyProxySeedsUsdc() public view {
        assertTrue(proxy.isBuySide());
        assertEq(address(proxy.seedToken()), address(usdc));
    }

    function test_side_sellProxySeedsWeth() public view {
        assertFalse(sellProxy.isBuySide());
        assertEq(address(sellProxy.seedToken()), address(weth));
    }

    /// @dev A buy proxy may never have WETH added to its declared balance.
    function test_side_buyProxyRejectsWethTopUp() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        vm.expectRevert(LadderProxy.WrongSide.selector);
        proxy.topUp(address(weth), 1e18);
        vm.stopPrank();
    }

    function test_side_sellProxyRejectsUsdcTopUp() public {
        vm.startPrank(manager);
        sellProxy.shipStrategy(app, STRATEGY, LOW, HIGH, 2e18);
        vm.expectRevert(LadderProxy.WrongSide.selector);
        sellProxy.topUp(address(usdc), 1000e6);
        vm.stopPrank();
    }

    /// @dev Ranged liquidity fills both ways, so a buy proxy WILL come to hold
    ///      WETH. The side constraint governs what goes IN, not what it ends
    ///      up holding — and sweep must still remove both.
    function test_side_buyProxyCanHoldBothAndSweepBoth() public {
        usdc.mint(address(proxy), 1000e6);
        weth.mint(address(proxy), 2e18); // as if acquired through a fill

        vm.prank(manager);
        proxy.sweep(manager);

        assertEq(usdc.balanceOf(manager), 1000e6);
        assertEq(weth.balanceOf(manager), 2e18);
    }

    function test_side_sellProxyCanHoldBothAndSweepBoth() public {
        weth.mint(address(sellProxy), 2e18);
        usdc.mint(address(sellProxy), 1000e6); // acquired through a fill

        vm.prank(manager);
        sellProxy.sweep(manager);

        assertEq(weth.balanceOf(manager), 2e18);
        assertEq(usdc.balanceOf(manager), 1000e6);
    }

    /// @dev Both tokens are always registered with Aqua, so dock (which
    ///      requires tokensCount == tokens.length) still works on both sides.
    function test_side_sellProxyDocks() public {
        vm.startPrank(manager);
        sellProxy.shipStrategy(app, STRATEGY, LOW, HIGH, 2e18);
        sellProxy.dockStrategy();
        vm.stopPrank();

        assertEq(sellProxy.strategyHash(), bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                          SALT ON SHIP
    //////////////////////////////////////////////////////////////*/

    function test_salt_derivedOnShip() public {
        assertEq(proxy.currentSalt(), 0);

        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        assertTrue(proxy.currentSalt() != 0);
    }

    function test_nonce_startsAtZero() public view {
        assertEq(proxy.nonce(), 0);
    }

    function test_nonce_advancesOnShip() public {
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        assertEq(proxy.nonce(), 1);
    }

    /// @dev Each proxy owns its own counter; one proxy shipping must not move
    ///      another's.
    function test_nonce_isPerProxy() public {
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        assertEq(proxy.nonce(), 1);
        assertEq(sellProxy.nonce(), 0);
    }

    /// @dev Nothing external can advance the counter — there is no setter, and
    ///      it moves only inside shipStrategy.
    function test_nonce_onlyMovesOnShip() public {
        usdc.mint(address(proxy), 1000e6);
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.topUp(address(usdc), 1);
        proxy.dockStrategy();
        vm.stopPrank();

        assertEq(proxy.nonce(), 1);
    }

    function test_nonce_monotonicAcrossReships() public {
        bytes memory b2 = hex"211426ffc7d378e8e49be2c483295a3e3e511f96a4682c";
        bytes memory b3 = hex"211426ffc7d378e8e49be2c483295a3e3e511f96a4683c";

        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        proxy.dockStrategy();
        proxy.shipStrategy(app, b2, LOW, HIGH, 1000e6);
        proxy.dockStrategy();
        proxy.shipStrategy(app, b3, LOW, HIGH, 1000e6);
        vm.stopPrank();

        assertEq(proxy.nonce(), 3);
    }

    /// @dev Two proxies shipping in the same block at the SAME nonce must
    ///      still get different salts — the proxy address in the domain is
    ///      what separates them.
    function test_salt_differsAcrossProxiesSameBlock() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        sellProxy.shipStrategy(app, STRATEGY, LOW, HIGH, 2e18);
        vm.stopPrank();

        assertEq(proxy.nonce(), 1);
        assertEq(sellProxy.nonce(), 1);
        assertTrue(proxy.currentSalt() != sellProxy.currentSalt());
    }

    /// @dev Re-shipping after a dock must produce a different salt, since the
    ///      old program bytes are permanently dead.
    function test_salt_changesOnReship() public {
        vm.startPrank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
        uint64 first = proxy.currentSalt();

        proxy.dockStrategy();

        bytes memory other = hex"211426ffc7d378e8e49be2c483295a3e3e511f96a4682c";
        proxy.shipStrategy(app, other, LOW, HIGH, 1000e6);
        vm.stopPrank();

        assertTrue(proxy.currentSalt() != first);
    }

    function test_salt_matchesLibrary() public {
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        assertEq(proxy.currentSalt(), SaltLib.compute(address(proxy), 1));
    }

    /// @dev nextSalt must predict the next ship without advancing the counter.
    function test_nextSalt_predictsAndDoesNotAdvance() public {
        uint64 predicted = proxy.nextSalt();
        assertEq(proxy.nonce(), 0);

        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);

        assertEq(proxy.currentSalt(), predicted);
    }

    /// @dev Salt no longer depends on block.timestamp: warping time must not
    ///      change the derived value for the same nonce.
    function test_salt_independentOfTimestamp() public {
        uint64 before = proxy.nextSalt();
        vm.warp(block.timestamp + 30 days);
        assertEq(proxy.nextSalt(), before);
    }

    function test_salt_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit LadderProxy.SaltDerived(proxy.nextSalt(), 1);
        vm.prank(manager);
        proxy.shipStrategy(app, STRATEGY, LOW, HIGH, 1000e6);
    }

    function testFuzz_salt_distinctNonces(uint64 a, uint64 b) public view {
        vm.assume(a != b);
        assertTrue(
            SaltLib.compute(address(proxy), a) != SaltLib.compute(address(proxy), b)
        );
    }

    function test_salt_variesByChainId() public pure {
        assertTrue(
            SaltLib.computeWithChainId(1, address(0xA1), 1)
                != SaltLib.computeWithChainId(8453, address(0xA1), 1)
        );
    }

    function test_salt_chainIdVariantsAgree() public view {
        assertEq(
            SaltLib.compute(address(proxy), 1),
            SaltLib.computeWithChainId(block.chainid, address(proxy), 1)
        );
    }
}
