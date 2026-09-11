// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RungMath
/// @notice Geometric price ladder. Rung 1000 is the anchor; +2.5% per rung up,
///         -2.5% per rung down. Spacing is asymmetric across 1000 by design.
///
/// @dev Pure. All prices are WAD (1e18) fixed point.
///
///      CANONICAL DEFINITION: a rung's price is always computed by walking
///      away from BASE_RUNG one step at a time:
///
///          price(1000)   = anchor
///          price(n)      = price(n-1) * 1.025    for n > 1000
///          price(n)      = price(n+1) * 0.975    for n < 1000
///
///      priceAt() is that walk, so stepUp()/stepDown() from a correct value
///      reproduce it EXACTLY. Caching a stepped result is therefore safe: a
///      cached price is bit-identical to the freshly computed one. Do not
///      replace the loop with exponentiation — pow-by-squaring rounds
///      differently and would desynchronise the cache from priceAt().
library RungMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BASE_RUNG = 1000;
    uint256 internal constant UP = 1.025e18;
    uint256 internal constant DOWN = 0.975e18;

    error PriceOutOfLadder();

    function _mulWad(uint256 a, uint256 b) private pure returns (uint256) {
        return (a * b) / WAD;
    }

    /// @notice Price one rung above `price`. One canonical step.
    function stepUp(uint256 price) internal pure returns (uint256) {
        return _mulWad(price, UP);
    }

    /// @notice Price one rung below `price`. One canonical step.
    function stepDown(uint256 price) internal pure returns (uint256) {
        return _mulWad(price, DOWN);
    }

    /// @notice Price of rung `n`, walked from the rung-1000 anchor.
    /// @dev O(|n - 1000|). Callers that iterate should step from a known
    ///      neighbour instead of calling this per rung.
    function priceAt(uint256 anchor, uint256 n) internal pure returns (uint256 p) {
        p = anchor;
        if (n > BASE_RUNG) {
            for (uint256 i = BASE_RUNG; i < n; ++i) {
                p = stepUp(p);
            }
        } else {
            for (uint256 i = n; i < BASE_RUNG; ++i) {
                p = stepDown(p);
            }
        }
    }

    /// @notice Highest rung whose price is <= `price`.
    /// @dev Walks from the anchor carrying the price, so each step is one
    ///      multiply rather than a fresh priceAt().
    function rungBelow(uint256 anchor, uint256 price) internal pure returns (uint256 n) {
        n = BASE_RUNG;
        uint256 p = anchor;

        if (p <= price) {
            uint256 next = stepUp(p);
            while (next <= price) {
                p = next;
                unchecked { ++n; }
                next = stepUp(p);
            }
        } else {
            while (p > price) {
                if (n == 0) revert PriceOutOfLadder();
                p = stepDown(p);
                unchecked { --n; }
            }
        }
    }

    /// @notice Lowest rung whose price is >= `price`.
    function rungAbove(uint256 anchor, uint256 price) internal pure returns (uint256 n) {
        n = rungBelow(anchor, price);
        if (priceAt(anchor, n) != price) n++;
    }
}
