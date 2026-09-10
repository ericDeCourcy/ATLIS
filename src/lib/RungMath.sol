// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RungMath
/// @notice Geometric price ladder. Rung 1000 is the anchor; +2.5% per rung up,
///         -2.5% per rung down. Spacing is asymmetric across 1000 by design.
/// @dev Pure. All prices are WAD (1e18) fixed point.
library RungMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BASE_RUNG = 1000;
    uint256 internal constant UP = 1.025e18;
    uint256 internal constant DOWN = 0.975e18;

    error PriceOutOfLadder();

    function _mulWad(uint256 a, uint256 b) private pure returns (uint256) {
        return (a * b) / WAD;
    }

    /// @dev base^e in WAD, by squaring.
    function _powWad(uint256 base, uint256 e) private pure returns (uint256 r) {
        r = WAD;
        while (e != 0) {
            if (e & 1 == 1) r = _mulWad(r, base);
            base = _mulWad(base, base);
            e >>= 1;
        }
    }

    /// @notice Price of rung `n` given the rung-1000 anchor price.
    function priceAt(uint256 anchor, uint256 n) internal pure returns (uint256) {
        return n >= BASE_RUNG
            ? _mulWad(anchor, _powWad(UP, n - BASE_RUNG))
            : _mulWad(anchor, _powWad(DOWN, BASE_RUNG - n));
    }

    /// @notice Price one rung above `price`.
    /// @dev Step helper for walking the ladder from a cached value. Use only to
    ///      locate a rung; recompute with priceAt() before shipping, since
    ///      repeated stepping accumulates truncation drift.
    function stepUp(uint256 price) internal pure returns (uint256) {
        return _mulWad(price, UP);
    }

    /// @notice Price one rung below `price`.
    function stepDown(uint256 price) internal pure returns (uint256) {
        return _mulWad(price, DOWN);
    }

    /// @notice Highest rung whose price is <= `price`.
    function rungBelow(uint256 anchor, uint256 price) internal pure returns (uint256 n) {
        n = BASE_RUNG;
        if (priceAt(anchor, n) <= price) {
            while (priceAt(anchor, n + 1) <= price) n++;
        } else {
            while (priceAt(anchor, n) > price) {
                if (n == 0) revert PriceOutOfLadder();
                n--;
            }
        }
    }

    /// @notice Lowest rung whose price is >= `price`.
    function rungAbove(uint256 anchor, uint256 price) internal pure returns (uint256 n) {
        n = rungBelow(anchor, price);
        if (priceAt(anchor, n) != price) n++;
    }
}
