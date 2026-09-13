// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DemoStrategyBuilder} from "../src/demo/DemoStrategyBuilder.sol";

/// @title DemoBuildStrategy
/// @notice Prints the `strategy` bytes for a maker + USDC/WETH price range.
///         No RPC or broadcast needed — it runs in Foundry's local EVM and
///         logs the result.
///
/// Usage (whole prices, e.g. 3000 = 3000 USDC/WETH):
///
///   Pass args directly:
///     forge script script/DemoBuildStrategy.s.sol \
///       --sig "run(address,uint256,uint256)" \
///       0xYourMakerAddress 3000 4000
///
///   Or via environment variables (default entrypoint):
///     MAKER=0xYourMakerAddress PRICE_MIN=3000 PRICE_MAX=4000 \
///       forge script script/DemoBuildStrategy.s.sol
///
/// The salt is derived from (maker, priceMin, priceMax), so the same inputs
/// always print the same bytes.
contract DemoBuildStrategy is Script {
    /// @notice Explicit-args entrypoint. Prices are whole USDC/WETH.
    function run(address maker, uint256 priceMinWhole, uint256 priceMaxWhole) public {
        DemoStrategyBuilder demo = new DemoStrategyBuilder();
        DemoStrategyBuilder.Result memory r =
            demo.buildFromWholePrices(maker, priceMinWhole, priceMaxWhole);
        _report(maker, priceMinWhole, priceMaxWhole, r);
    }

    /// @notice Env-var entrypoint (used when no --sig is given). Reads MAKER,
    ///         PRICE_MIN, PRICE_MAX. Prices are whole USDC/WETH.
    function run() external {
        address maker = vm.envAddress("MAKER");
        uint256 priceMin = vm.envUint("PRICE_MIN");
        uint256 priceMax = vm.envUint("PRICE_MAX");
        run(maker, priceMin, priceMax);
    }

    function _report(
        address maker,
        uint256 priceMinWhole,
        uint256 priceMaxWhole,
        DemoStrategyBuilder.Result memory r
    ) internal view {
        console2.log("=== DemoStrategyBuilder ===");
        console2.log("maker        :", maker);
        console2.log("priceMin (USDC/WETH):", priceMinWhole);
        console2.log("priceMax (USDC/WETH):", priceMaxWhole);
        console2.log("sqrtMin      :", r.sqrtMin);
        console2.log("sqrtMax      :", r.sqrtMax);
        console2.log("salt (uint64):", uint256(r.salt));
        console2.log("strategy len :", r.strategy.length);
        console2.log("strategy bytes:");
        console2.logBytes(r.strategy);
    }
}
