// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RungMath} from "../src/lib/RungMath.sol";
import {RungRegistry} from "../src/RungRegistry.sol";

contract RungRegistryTest is Test {
    uint256 constant ANCHOR = 3000e18;
    uint256 constant BASE = RungMath.BASE_RUNG;

    RungRegistry registry;
    address stranger = address(0xBEEF);
    address proxy = address(0xCAFE);

    function setUp() public {
        registry = new RungRegistry(ANCHOR);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_anchorStored() public view {
        assertEq(registry.anchor(), ANCHOR);
    }

    function test_anchorRungCachedOnDeploy() public view {
        assertEq(registry.priceOf(BASE), ANCHOR);
    }

    function test_revertsOnZeroAnchor() public {
        vm.expectRevert(bytes("anchor=0"));
        new RungRegistry(0);
    }

    /*//////////////////////////////////////////////////////////////
                              GET PRICE
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_cachesOnMiss() public {
        assertEq(registry.priceOf(BASE + 5), 0);

        uint256 p = registry.getPrice(BASE + 5);

        assertEq(p, RungMath.priceAt(ANCHOR, BASE + 5));
        assertEq(registry.priceOf(BASE + 5), p);
    }

    function test_getPrice_stableAcrossCalls() public {
        assertEq(registry.getPrice(BASE + 3), registry.getPrice(BASE + 3));
    }

    /*//////////////////////////////////////////////////////////////
                            PROXY REGISTRY
    //////////////////////////////////////////////////////////////*/

    function test_setAddress_buy() public {
        registry.setAddress(BASE - 1, true, proxy);
        assertEq(registry.buyProxyAt(BASE - 1), proxy);
        assertEq(registry.sellProxyAt(BASE - 1), address(0));
    }

    function test_setAddress_sell() public {
        registry.setAddress(BASE + 2, false, proxy);
        assertEq(registry.sellProxyAt(BASE + 2), proxy);
        assertEq(registry.buyProxyAt(BASE + 2), address(0));
    }

    /// @dev Both sides may register at the same rung independently.
    function test_setAddress_sidesIndependent() public {
        registry.setAddress(BASE, true, address(0xA1));
        registry.setAddress(BASE, false, address(0xB2));

        assertEq(registry.buyProxyAt(BASE), address(0xA1));
        assertEq(registry.sellProxyAt(BASE), address(0xB2));
    }

    function test_setAddress_overwrites() public {
        registry.setAddress(BASE, true, proxy);
        registry.setAddress(BASE, true, address(0xD00D));
        assertEq(registry.buyProxyAt(BASE), address(0xD00D));
    }

    function test_setAddress_revertsOnZero() public {
        vm.expectRevert(bytes("proxy=0"));
        registry.setAddress(BASE, true, address(0));
    }

    function test_setAddress_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        registry.setAddress(BASE, true, proxy);
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Every cached price must equal the canonical computation.
    function test_cacheMatchesCanonical() public {
        for (uint256 n = BASE - 6; n <= BASE + 6; n++) {
            registry.getPrice(n);
        }
        for (uint256 n = BASE - 6; n <= BASE + 6; n++) {
            assertEq(registry.priceOf(n), RungMath.priceAt(ANCHOR, n));
        }
    }

    function test_cachedPricesMonotonic() public {
        uint256 prev;
        for (uint256 n = BASE - 6; n <= BASE + 6; n++) {
            uint256 p = registry.getPrice(n);
            if (prev != 0) assertGt(p, prev);
            prev = p;
        }
    }

    function testFuzz_cacheMatchesCanonical(uint16 n) public {
        uint256 rung = bound(n, BASE - 60, BASE + 60);
        assertEq(registry.getPrice(rung), RungMath.priceAt(ANCHOR, rung));
    }

    /*//////////////////////////////////////////////////////////////
        PATH INDEPENDENCE
        getPrice walks from whichever band edge is nearest, so the same
        rung can be reached from different starting points. Every route
        must land on the identical value.
    //////////////////////////////////////////////////////////////*/

    /// @dev One cold jump vs. many incremental extensions.
    function test_pathIndependence_up() public {
        RungRegistry jumpy = new RungRegistry(ANCHOR);
        RungRegistry stepwise = new RungRegistry(ANCHOR);

        jumpy.getPrice(BASE + 33); // single 33-rung walk from the anchor

        for (uint256 i = 1; i <= 33; i++) {
            stepwise.getPrice(BASE + i); // 33 one-rung extensions
        }

        assertEq(jumpy.priceOf(BASE + 33), stepwise.priceOf(BASE + 33));
        assertEq(jumpy.priceOf(BASE + 33), RungMath.priceAt(ANCHOR, BASE + 33));
    }

    function test_pathIndependence_down() public {
        RungRegistry jumpy = new RungRegistry(ANCHOR);
        RungRegistry stepwise = new RungRegistry(ANCHOR);

        jumpy.getPrice(BASE - 33);

        for (uint256 i = 1; i <= 33; i++) {
            stepwise.getPrice(BASE - i);
        }

        assertEq(jumpy.priceOf(BASE - 33), stepwise.priceOf(BASE - 33));
        assertEq(jumpy.priceOf(BASE - 33), RungMath.priceAt(ANCHOR, BASE - 33));
    }

    /// @dev Partial jump then extend must equal a single jump to the same rung.
    function test_pathIndependence_partialThenExtend() public {
        RungRegistry split = new RungRegistry(ANCHOR);
        RungRegistry direct = new RungRegistry(ANCHOR);

        split.getPrice(BASE + 20); // walks from anchor
        split.getPrice(BASE + 25); // extends 5 from hiCached

        direct.getPrice(BASE + 25);

        assertEq(split.priceOf(BASE + 25), direct.priceOf(BASE + 25));
    }

    /// @dev Extending both directions in either order gives the same band.
    function test_pathIndependence_orderOfDirections() public {
        RungRegistry upFirst = new RungRegistry(ANCHOR);
        RungRegistry downFirst = new RungRegistry(ANCHOR);

        upFirst.getPrice(BASE + 12);
        upFirst.getPrice(BASE - 12);

        downFirst.getPrice(BASE - 12);
        downFirst.getPrice(BASE + 12);

        for (uint256 n = BASE - 12; n <= BASE + 12; n++) {
            assertEq(upFirst.priceOf(n), downFirst.priceOf(n));
        }
    }

    /// @dev Any access order yields canonical values.
    function testFuzz_anyAccessOrder(uint16 a, uint16 b, uint16 c) public {
        uint256 r1 = bound(a, BASE - 40, BASE + 40);
        uint256 r2 = bound(b, BASE - 40, BASE + 40);
        uint256 r3 = bound(c, BASE - 40, BASE + 40);

        RungRegistry r = new RungRegistry(ANCHOR);
        assertEq(r.getPrice(r1), RungMath.priceAt(ANCHOR, r1));
        assertEq(r.getPrice(r2), RungMath.priceAt(ANCHOR, r2));
        assertEq(r.getPrice(r3), RungMath.priceAt(ANCHOR, r3));
    }

    /*//////////////////////////////////////////////////////////////
        BAND CONTIGUITY
        INVARIANT: every rung in [loCached, hiCached] is populated.
        getPrice short-circuits on an in-band rung and returns priceOf
        without a zero check, so a hole would silently return 0.
    //////////////////////////////////////////////////////////////*/

    function test_bandStartsAtAnchor() public view {
        assertEq(registry.loCached(), BASE);
        assertEq(registry.hiCached(), BASE);
    }

    function test_bandContiguousAfterUpwardJump() public {
        registry.getPrice(BASE + 40);

        assertEq(registry.loCached(), BASE);
        assertEq(registry.hiCached(), BASE + 40);

        for (uint256 n = BASE; n <= BASE + 40; n++) {
            assertTrue(registry.priceOf(n) != 0, "hole in band");
            assertEq(registry.priceOf(n), RungMath.priceAt(ANCHOR, n));
        }
    }

    function test_bandContiguousAfterDownwardJump() public {
        registry.getPrice(BASE - 40);

        assertEq(registry.loCached(), BASE - 40);
        assertEq(registry.hiCached(), BASE);

        for (uint256 n = BASE - 40; n <= BASE; n++) {
            assertTrue(registry.priceOf(n) != 0, "hole in band");
            assertEq(registry.priceOf(n), RungMath.priceAt(ANCHOR, n));
        }
    }

    function test_bandContiguousBothDirections() public {
        registry.getPrice(BASE + 15);
        registry.getPrice(BASE - 15);

        assertEq(registry.loCached(), BASE - 15);
        assertEq(registry.hiCached(), BASE + 15);

        for (uint256 n = BASE - 15; n <= BASE + 15; n++) {
            assertTrue(registry.priceOf(n) != 0, "hole in band");
            assertEq(registry.priceOf(n), RungMath.priceAt(ANCHOR, n));
        }
    }

    /// @dev An in-band query must not move the watermarks.
    function test_inBandQueryDoesNotExtendBand() public {
        registry.getPrice(BASE + 20);
        registry.getPrice(BASE + 10); // already inside the band

        assertEq(registry.loCached(), BASE);
        assertEq(registry.hiCached(), BASE + 20);
    }

    /// @dev Re-querying the current edge is a no-op.
    function test_queryingEdgeIsNoop() public {
        registry.getPrice(BASE + 10);
        uint256 p = registry.getPrice(BASE + 10);

        assertEq(registry.hiCached(), BASE + 10);
        assertEq(p, RungMath.priceAt(ANCHOR, BASE + 10));
    }

    function testFuzz_bandAlwaysContiguous(uint16 a, uint16 b) public {
        uint256 hi = bound(a, BASE, BASE + 30);
        uint256 lo = bound(b, BASE - 30, BASE);

        registry.getPrice(hi);
        registry.getPrice(lo);

        assertEq(registry.hiCached(), hi);
        assertEq(registry.loCached(), lo);

        for (uint256 n = lo; n <= hi; n++) {
            assertTrue(registry.priceOf(n) != 0, "hole in band");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              FAR JUMPS
    //////////////////////////////////////////////////////////////*/

    function test_farJumpUp_canonical() public {
        uint256 far = BASE + 100;
        assertEq(registry.priceOf(far), 0);
        assertEq(registry.getPrice(far), RungMath.priceAt(ANCHOR, far));
    }

    function test_farJumpDown_canonical() public {
        uint256 far = BASE - 100;
        assertEq(registry.priceOf(far), 0);
        assertEq(registry.getPrice(far), RungMath.priceAt(ANCHOR, far));
    }

    /// @dev A far jump must not corrupt the opposite edge.
    function test_farJumpLeavesOppositeEdgeIntact() public {
        registry.getPrice(BASE - 50);
        registry.getPrice(BASE + 50);

        assertEq(registry.loCached(), BASE - 50);
        assertEq(registry.priceOf(BASE - 50), RungMath.priceAt(ANCHOR, BASE - 50));
        assertEq(registry.priceOf(BASE + 50), RungMath.priceAt(ANCHOR, BASE + 50));
    }

    /// @dev Prices stay strictly monotonic across a wide band.
    function test_farBandMonotonic() public {
        registry.getPrice(BASE + 60);
        registry.getPrice(BASE - 60);

        uint256 prev;
        for (uint256 n = BASE - 60; n <= BASE + 60; n++) {
            uint256 p = registry.priceOf(n);
            if (prev != 0) assertGt(p, prev);
            prev = p;
        }
    }
}
