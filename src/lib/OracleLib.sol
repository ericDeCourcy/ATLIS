// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Chainlink aggregator surface. Declared locally so the repo
///         takes no external dependency; only these two views are used.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title OracleLib
/// @notice Reads a Chainlink price feed and normalises it to the one format the
///         Manager works in: a WAD (1e18) spot price of USDC per 1 WETH — the
///         same units as RungMath prices and AquaPriceMath inputs.
///
/// @dev PAIR ASSUMPTION. The Base feed the Manager is wired to quotes ETH in
///      USD. USDC is treated as 1 USD, so USD-per-ETH is used directly as
///      USDC-per-WETH. If a USDC-denominated feed is ever substituted the
///      output is already correct; only the USD≈USDC peg assumption changes.
///
///      DECIMALS. The feed's own `decimals()` is read on-chain and scaled to
///      WAD, so an 8-decimal USD feed (the common case) and any other width are
///      both handled without a hard-coded exponent.
///
///      SAFETY. Reverts on a non-positive answer, an incomplete round, or a
///      quote older than `maxStaleness`. A ladder must never place rungs
///      against a stale or zero price, so failing closed is correct here.
library OracleLib {
    error StalePrice(uint256 updatedAt, uint256 maxStaleness);
    error NonPositiveAnswer(int256 answer);
    error IncompleteRound();

    uint256 internal constant WAD = 1e18;

    /// @notice Current spot as WAD USDC-per-WETH.
    /// @param feed The Chainlink aggregator.
    /// @param maxStaleness Max age in seconds; 0 disables the freshness check.
    function readSpotWad(IAggregatorV3 feed, uint256 maxStaleness)
        internal
        view
        returns (uint256 spotWad)
    {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();

        if (answer <= 0) revert NonPositiveAnswer(answer);
        if (updatedAt == 0 || answeredInRound < roundId) revert IncompleteRound();
        if (maxStaleness != 0 && block.timestamp - updatedAt > maxStaleness) {
            revert StalePrice(updatedAt, maxStaleness);
        }

        spotWad = _scaleToWad(uint256(answer), feed.decimals());
    }

    /// @dev Scales a raw feed answer with `feedDecimals` places to WAD.
    function _scaleToWad(uint256 answer, uint8 feedDecimals) private pure returns (uint256) {
        if (feedDecimals == 18) return answer;
        if (feedDecimals < 18) return answer * (10 ** (18 - feedDecimals));
        return answer / (10 ** (feedDecimals - 18));
    }
}
