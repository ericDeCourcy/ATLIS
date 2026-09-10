// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AquaPrice
/// @notice Converts between human prices and Aqua/SwapVM sqrt-price encoding.
///
/// @dev Encoding: sqrtPrice = isqrt(rawPrice * 1e36), where rawPrice is the
///      base-unit ratio token1/token0. Equivalently, for a quote token with
///      `quoteDecimals` and a base token with `baseDecimals`:
///
///          sqrtPrice = isqrt(price * 10 ** (36 + quoteDecimals - baseDecimals))
///
///      For USDC(6)/WETH(18) the exponent is 24. Verified against known values:
///          3000 USDC/WETH -> 0x31d0a8d8f974
///          4000 USDC/WETH -> 0x398580bb78a7
///          2500 USDC/WETH -> 0x2d79883d2000
library AquaPriceMath {
    /// @dev Scale exponent for a USDC(6) / WETH(18) pair.
    uint256 internal constant USDC_WETH_EXP = 24;

    error PriceZero();

    /// @notice Integer square root (Newton).
    function isqrt(uint256 n) internal pure returns (uint256 x) {
        if (n == 0) return 0;
        x = n;
        uint256 y = (x + 1) >> 1;
        while (y < x) {
            x = y;
            y = (x + n / x) >> 1;
        }
    }

    /// @notice Encode a price into Aqua sqrt form.
    /// @param price Quote units per 1 whole base token, WAD (1e18) fixed point.
    /// @param exp Scale exponent: 36 + quoteDecimals - baseDecimals.
    function toSqrtPrice(uint256 price, uint256 exp) internal pure returns (uint256) {
        if (price == 0) revert PriceZero();
        // price is WAD, so divide the extra 1e18 back out.
        return isqrt((price * 10 ** exp) / 1e18);
    }

    /// @notice Decode an Aqua sqrt price back to a WAD price.
    function fromSqrtPrice(uint256 sqrtPrice, uint256 exp) internal pure returns (uint256) {
        return (sqrtPrice * sqrtPrice * 1e18) / 10 ** exp;
    }

    /// @notice USDC-per-WETH convenience wrappers.
    function toSqrtPriceUsdcWeth(uint256 price) internal pure returns (uint256) {
        return toSqrtPrice(price, USDC_WETH_EXP);
    }

    function fromSqrtPriceUsdcWeth(uint256 sqrtPrice) internal pure returns (uint256) {
        return fromSqrtPrice(sqrtPrice, USDC_WETH_EXP);
    }
}
