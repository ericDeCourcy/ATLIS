// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {RungMath} from "../src/lib/RungMath.sol";
import {RungRegistry} from "../src/RungRegistry.sol";

contract DenseTest is Test {
    uint256 constant ANCHOR = 3000e18;
    uint256 constant BASE = RungMath.BASE_RUNG;

    /// A single far jump must populate every intervening rung.
    function test_bandIsContiguous() public {
        RungRegistry r = new RungRegistry(ANCHOR);

        r.getPrice(BASE + 40);   // hiCached = 1040

        assertEq(r.loCached(), BASE);
        assertEq(r.hiCached(), BASE + 40);

        // no holes: every rung in the band is stored and canonical
        for (uint256 n = BASE; n <= BASE + 40; n++) {
            assertTrue(r.priceOf(n) != 0, "hole in band");
            assertEq(r.priceOf(n), RungMath.priceAt(ANCHOR, n));
        }
    }

    /// Extending downward keeps the whole band contiguous.
    function test_bandContiguousBothDirections() public {
        RungRegistry r = new RungRegistry(ANCHOR);

        r.getPrice(BASE + 15);
        r.getPrice(BASE - 15);

        assertEq(r.loCached(), BASE - 15);
        assertEq(r.hiCached(), BASE + 15);

        for (uint256 n = BASE - 15; n <= BASE + 15; n++) {
            assertTrue(r.priceOf(n) != 0, "hole in band");
            assertEq(r.priceOf(n), RungMath.priceAt(ANCHOR, n));
        }
    }

    /// Two registries reaching the same rung by different paths must agree.
    function test_pathIndependence() public {
        RungRegistry jumpy = new RungRegistry(ANCHOR);
        RungRegistry stepwise = new RungRegistry(ANCHOR);

        jumpy.getPrice(BASE + 30);           // one big jump
        jumpy.getPrice(BASE + 33);           // then 3 more from hiCached

        for (uint256 i = 1; i <= 33; i++) {  // one rung at a time
            stepwise.getPrice(BASE + i);
        }

        assertEq(jumpy.priceOf(BASE + 33), stepwise.priceOf(BASE + 33));
        assertEq(jumpy.priceOf(BASE + 33), RungMath.priceAt(ANCHOR, BASE + 33));
    }

    /// Same, downward, and across the anchor boundary.
    function test_pathIndependence_downAndAcross() public {
        RungRegistry r = new RungRegistry(ANCHOR);
        r.getPrice(BASE - 25);               // jump down, loCached = 975
        r.getPrice(BASE - 27);               // extend from loCached
        r.getPrice(BASE + 12);               // now jump up across the anchor

        assertEq(r.priceOf(BASE - 27), RungMath.priceAt(ANCHOR, BASE - 27));
        assertEq(r.priceOf(BASE + 12), RungMath.priceAt(ANCHOR, BASE + 12));
    }

    /// Fuzz: any sequence of jumps still yields canonical values.
    function testFuzz_anyAccessOrder(uint16 a, uint16 b, uint16 c) public {
        uint256 r1 = bound(a, BASE - 50, BASE + 50);
        uint256 r2 = bound(b, BASE - 50, BASE + 50);
        uint256 r3 = bound(c, BASE - 50, BASE + 50);

        RungRegistry r = new RungRegistry(ANCHOR);
        assertEq(r.getPrice(r1), RungMath.priceAt(ANCHOR, r1));
        assertEq(r.getPrice(r2), RungMath.priceAt(ANCHOR, r2));
        assertEq(r.getPrice(r3), RungMath.priceAt(ANCHOR, r3));
    }
}
