// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AquaPriceMath} from "../src/lib/AquaPriceMath.sol";

/// @dev Internal library calls are inlined, so a revert happens at the same
///      call depth as the cheatcode. This harness pushes it one frame deeper
///      so vm.expectRevert can observe it.
contract PriceHarness {
    function toSqrtPriceUsdcWeth(uint256 p) external pure returns (uint256) {
        return AquaPriceMath.toSqrtPriceUsdcWeth(p);
    }
}

contract AquaPriceMathTest is Test {
    /*//////////////////////////////////////////////////////////////
        GOLDEN VECTORS
        Encodings taken from real shipped strategies. If one of these
        fails, the encoder is wrong — do not adjust the expected value.
    //////////////////////////////////////////////////////////////*/

    function test_golden_2500() public pure {
        assertEq(AquaPriceMath.toSqrtPriceUsdcWeth(2500e18), 0x2d79883d2000);
    }

    function test_golden_3000() public pure {
        assertEq(AquaPriceMath.toSqrtPriceUsdcWeth(3000e18), 0x31d0a8d8f974);
    }

    function test_golden_3001() public pure {
        assertEq(AquaPriceMath.toSqrtPriceUsdcWeth(3001e18), 0x31d2c8ea6b09);
    }

    function test_golden_4000() public pure {
        assertEq(AquaPriceMath.toSqrtPriceUsdcWeth(4000e18), 0x398580bb78a7);
    }

    /*//////////////////////////////////////////////////////////////
                                ISQRT
    //////////////////////////////////////////////////////////////*/

    function test_isqrt_zero() public pure {
        assertEq(AquaPriceMath.isqrt(0), 0);
    }

    function test_isqrt_perfectSquares() public pure {
        assertEq(AquaPriceMath.isqrt(1), 1);
        assertEq(AquaPriceMath.isqrt(4), 2);
        assertEq(AquaPriceMath.isqrt(1e18), 1e9);
    }

    /// @dev isqrt must floor, never round up.
    function testFuzz_isqrt_floors(uint128 n) public pure {
        uint256 r = AquaPriceMath.isqrt(n);
        assertLe(r * r, uint256(n));
        assertGt((r + 1) * (r + 1), uint256(n));
    }

    /*//////////////////////////////////////////////////////////////
                              ROUND TRIP
    //////////////////////////////////////////////////////////////*/

    /// @dev Encoding floors, so decoding lands at or just below the input.
    function testFuzz_roundTrip(uint256 price) public pure {
        price = bound(price, 1e18, 1_000_000e18);

        uint256 s = AquaPriceMath.toSqrtPriceUsdcWeth(price);
        uint256 back = AquaPriceMath.fromSqrtPriceUsdcWeth(s);

        assertLe(back, price);
        assertApproxEqRel(back, price, 1e9); // 1e-9 relative
    }

    /*//////////////////////////////////////////////////////////////
                             MONOTONICITY
    //////////////////////////////////////////////////////////////*/

    function testFuzz_monotonic(uint256 a, uint256 b) public pure {
        a = bound(a, 1e18, 1_000_000e18);
        b = bound(b, 1e18, 1_000_000e18);
        vm.assume(a < b);
        assertLe(
            AquaPriceMath.toSqrtPriceUsdcWeth(a),
            AquaPriceMath.toSqrtPriceUsdcWeth(b)
        );
    }

    /// @dev Neighbouring rungs are 2.5% apart and must encode distinctly.
    function test_adjacentRungPricesDistinct() public pure {
        uint256 lo = AquaPriceMath.toSqrtPriceUsdcWeth(3000e18);
        uint256 hi = AquaPriceMath.toSqrtPriceUsdcWeth(3075e18);
        assertGt(hi, lo);
    }

    /*//////////////////////////////////////////////////////////////
                          REVERTS / DECIMALS
    //////////////////////////////////////////////////////////////*/

    function test_revertsOnZero() public {
        PriceHarness h = new PriceHarness();
        vm.expectRevert(AquaPriceMath.PriceZero.selector);
        h.toSqrtPriceUsdcWeth(0);
    }

    /// @dev exp = 36 + quoteDecimals - baseDecimals; an 18/18 pair gives 36.
    function test_customExponent_sameDecimals() public pure {
        assertEq(AquaPriceMath.toSqrtPrice(1e18, 36), 1e18);
    }
}
