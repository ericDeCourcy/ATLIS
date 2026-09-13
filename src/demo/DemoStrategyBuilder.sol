// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StrategyBuilder} from "../lib/StrategyBuilder.sol";
import {AquaPriceMath} from "../lib/AquaPriceMath.sol";

/// @title DemoStrategyBuilder
/// @notice Demo wrapper that turns a maker address and a human USDC/WETH price
///         range into the exact `strategy` bytes `Aqua.ship` consumes, using
///         the production `AquaPriceMath` and `StrategyBuilder` libraries.
///
/// @dev The salt is derived deterministically from (maker, priceMin, priceMax),
///      so a given set of inputs ALWAYS produces byte-identical output. Prices
///      are keyed in WAD form internally, so the whole-price and WAD-price entry
///      points agree for equivalent inputs.
///
///      The returned bytes are the ABI-encoded `Strategy` wrapper (~288 bytes),
///      which is what `ship` hashes and what `LadderProxy.shipStrategy` forwards
///      — not the inner 132-byte program.
contract DemoStrategyBuilder {
    /// @dev Everything needed to inspect or reproduce a build.
    struct Result {
        uint256 sqrtMin; // Aqua sqrt-price encoding of priceMin
        uint256 sqrtMax; // Aqua sqrt-price encoding of priceMax
        uint64 salt; // deterministic salt for these inputs
        bytes strategy; // ABI-encoded Strategy wrapper for Aqua.ship
    }

    /// @notice Build from WAD prices — USDC per whole WETH, 1e18 fixed point
    ///         (e.g. 3000 USDC/WETH == 3000e18).
    /// @param maker       The maker/owner recorded in the strategy (the proxy).
    /// @param priceMinWad Lower price bound, WAD. Must be > 0 and < priceMaxWad.
    /// @param priceMaxWad Upper price bound, WAD.
    function buildFromWadPrices(address maker, uint256 priceMinWad, uint256 priceMaxWad)
        public
        pure
        returns (Result memory r)
    {
        r.sqrtMin = AquaPriceMath.toSqrtPriceUsdcWeth(priceMinWad);
        r.sqrtMax = AquaPriceMath.toSqrtPriceUsdcWeth(priceMaxWad);
        r.salt = deriveSalt(maker, priceMinWad, priceMaxWad);
        // build reverts (BadPriceBounds) if sqrtMin == 0 || sqrtMin >= sqrtMax.
        r.strategy = StrategyBuilder.build(maker, r.sqrtMin, r.sqrtMax, r.salt);
    }

    /// @notice Build from whole prices — e.g. 3000 means 3000 USDC/WETH. Scaled
    ///         to WAD internally, so the salt matches `buildFromWadPrices` for
    ///         the equivalent WAD inputs.
    function buildFromWholePrices(address maker, uint256 priceMinWhole, uint256 priceMaxWhole)
        external
        pure
        returns (Result memory)
    {
        return buildFromWadPrices(maker, priceMinWhole * 1e18, priceMaxWhole * 1e18);
    }

    /// @notice Deterministic salt from the inputs: keccak256 over the tuple,
    ///         truncated to the uint64 the SwapVM salt slot holds. Keyed on the
    ///         WAD prices, so it is a pure function of (maker, priceMin, priceMax).
    function deriveSalt(address maker, uint256 priceMinWad, uint256 priceMaxWad)
        public
        pure
        returns (uint64)
    {
        return uint64(uint256(keccak256(abi.encode(maker, priceMinWad, priceMaxWad))));
    }

    /// @notice Convenience: encode a single WAD price to its Aqua sqrt price.
    function priceToSqrt(uint256 priceWad) external pure returns (uint256) {
        return AquaPriceMath.toSqrtPriceUsdcWeth(priceWad);
    }

    /// @notice Convenience: decode an Aqua sqrt price back to a WAD price.
    function sqrtToPrice(uint256 sqrtPrice) external pure returns (uint256) {
        return AquaPriceMath.fromSqrtPriceUsdcWeth(sqrtPrice);
    }
}
