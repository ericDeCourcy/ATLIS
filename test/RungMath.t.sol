// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RungMath} from "../src/lib/RungMath.sol";

/// @dev Library calls are inlined; this harness pushes reverts one frame
///      deeper so vm.expectRevert can observe them.
contract RungHarness {
    function rungBelow(uint256 anchor, uint256 price) external pure returns (uint256) {
        return RungMath.rungBelow(anchor, price);
    }
}

contract RungMathTest is Test {
    uint256 constant ANCHOR = 3000e18; // rung 1000 = 3000 USDC/WETH
    uint256 constant BASE = RungMath.BASE_RUNG;

    /*//////////////////////////////////////////////////////////////
                               PRICE AT
    //////////////////////////////////////////////////////////////*/

    function test_anchorRung() public pure {
        assertEq(RungMath.priceAt(ANCHOR, BASE), ANCHOR);
    }

    function test_oneRungUp() public pure {
        assertEq(RungMath.priceAt(ANCHOR, BASE + 1), 3075e18);
    }

    function test_oneRungDown() public pure {
        assertEq(RungMath.priceAt(ANCHOR, BASE - 1), 2925e18);
    }

    /// @dev The ladder is asymmetric across 1000: up is 2.5%, down is ~2.564%.
    ///      Stepping down then back up must NOT return to the anchor.
    function test_ladderIsAsymmetric() public pure {
        uint256 backUp = RungMath.stepUp(RungMath.priceAt(ANCHOR, BASE - 1));
        assertLt(backUp, ANCHOR);
    }

    function test_monotonicAcrossBoundary() public pure {
        uint256 prev;
        for (uint256 n = BASE - 5; n <= BASE + 5; n++) {
            uint256 p = RungMath.priceAt(ANCHOR, n);
            if (prev != 0) assertGt(p, prev);
            prev = p;
        }
    }

    function testFuzz_monotonic(uint16 a, uint16 b) public pure {
        uint256 lo = bound(a, BASE - 100, BASE + 100);
        uint256 hi = bound(b, BASE - 100, BASE + 100);
        vm.assume(lo < hi);
        assertLt(RungMath.priceAt(ANCHOR, lo), RungMath.priceAt(ANCHOR, hi));
    }

    /*//////////////////////////////////////////////////////////////
        CANONICAL DEFINITION
        priceAt IS the iterated walk, so stepping must reproduce it
        EXACTLY — not approximately. These are the tests that make
        caching stepped values safe.
    //////////////////////////////////////////////////////////////*/

    function test_stepUp_exactlyMatchesPriceAt() public pure {
        assertEq(
            RungMath.stepUp(RungMath.priceAt(ANCHOR, BASE)),
            RungMath.priceAt(ANCHOR, BASE + 1)
        );
    }

    function test_stepDown_exactlyMatchesPriceAt() public pure {
        assertEq(
            RungMath.stepDown(RungMath.priceAt(ANCHOR, BASE)),
            RungMath.priceAt(ANCHOR, BASE - 1)
        );
    }

    /// @dev Walking N rungs up must equal priceAt(BASE+N) bit for bit.
    function test_walkingUp_noDrift() public pure {
        uint256 walked = ANCHOR;
        for (uint256 i = 0; i < 50; i++) {
            walked = RungMath.stepUp(walked);
            assertEq(walked, RungMath.priceAt(ANCHOR, BASE + i + 1));
        }
    }

    function test_walkingDown_noDrift() public pure {
        uint256 walked = ANCHOR;
        for (uint256 i = 0; i < 50; i++) {
            walked = RungMath.stepDown(walked);
            assertEq(walked, RungMath.priceAt(ANCHOR, BASE - i - 1));
        }
    }

    /// @dev Any rung reached by stepping from its neighbour equals priceAt.
    function testFuzz_stepFromNeighbour_exact(uint16 n) public pure {
        uint256 rung = bound(n, BASE + 1, BASE + 120);
        assertEq(
            RungMath.stepUp(RungMath.priceAt(ANCHOR, rung - 1)),
            RungMath.priceAt(ANCHOR, rung)
        );
    }

    function testFuzz_stepDownFromNeighbour_exact(uint16 n) public pure {
        uint256 rung = bound(n, BASE - 120, BASE - 1);
        assertEq(
            RungMath.stepDown(RungMath.priceAt(ANCHOR, rung + 1)),
            RungMath.priceAt(ANCHOR, rung)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          RUNG BELOW / ABOVE
    //////////////////////////////////////////////////////////////*/

    /// @dev The core round-trip property.
    function testFuzz_rungBelow_roundTrip(uint16 n) public pure {
        uint256 rung = bound(n, BASE - 100, BASE + 100);
        uint256 price = RungMath.priceAt(ANCHOR, rung);
        assertEq(RungMath.rungBelow(ANCHOR, price), rung);
    }

    function test_rungBelow_exactAnchor() public pure {
        assertEq(RungMath.rungBelow(ANCHOR, ANCHOR), BASE);
    }

    function test_rungAbove_exactAnchor() public pure {
        assertEq(RungMath.rungAbove(ANCHOR, ANCHOR), BASE);
    }

    function test_bracketsBetweenRungs() public pure {
        uint256 mid = (RungMath.priceAt(ANCHOR, BASE) + RungMath.priceAt(ANCHOR, BASE + 1)) / 2;

        assertEq(RungMath.rungBelow(ANCHOR, mid), BASE);
        assertEq(RungMath.rungAbove(ANCHOR, mid), BASE + 1);
    }

    /// @dev below <= price <= above, and they are adjacent (or equal on a hit).
    function testFuzz_bracketInvariant(uint256 price) public pure {
        price = bound(price, 100e18, 50_000e18);

        uint256 below = RungMath.rungBelow(ANCHOR, price);
        uint256 above = RungMath.rungAbove(ANCHOR, price);

        assertLe(RungMath.priceAt(ANCHOR, below), price);
        assertGe(RungMath.priceAt(ANCHOR, above), price);
        assertLe(above - below, 1);
    }

    /*//////////////////////////////////////////////////////////////
                               BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @dev Rung 0 is ~1e-11 of the anchor — an effectively unreachable floor.
    ///      3000e18 * 0.975^1000 ~= 3.03e10 wei, i.e. 3.03e-8 in human terms.
    ///      That 1000 iterated truncations land on the exact real value shows
    ///      the iterative definition does not accumulate meaningful drift.
    function test_rungZeroIsVanishinglySmall() public pure {
        uint256 p = RungMath.priceAt(ANCHOR, 0);
        assertLt(p, ANCHOR / 1e9);
        assertGt(p, 0); // still nonzero, so the ladder never bottoms out at 0
    }

    function test_revertsBelowLadder() public {
        RungHarness h = new RungHarness();
        vm.expectRevert(RungMath.PriceOutOfLadder.selector);
        h.rungBelow(ANCHOR, 1);
    }
}
