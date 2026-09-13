// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RungMath} from "./RungMath.sol";

/// @title Placement
/// @notice Pure rung placement for a rebalance. Given the ladder anchor, the
///         current spot (WAD USDC/WETH) and the current average entry (WAD, or
///         0 when inventory is empty), it produces the six-rung band for each
///         side and a flag for whether the immediate Uniswap trade fires.
///
/// @dev Both sides are CLAMPED so a band boundary never sits at or beyond the
///      relevant anchors:
///
///        buy:  rl = min( rungBelow(spot), rungBelow(avgEntry) )
///        sell: rh = max( rungAbove(spot), rungAbove(avgEntry) )
///
///      A 0.5% BUFFER is then applied to SPOT ONLY (the oracle spot may differ
///      slightly from live market): if the buy band's top would sit within
///      0.5% below spot, the band is stepped one rung further down and the
///      GROWTH trade fires; symmetrically for the sell band's bottom within
///      0.5% above spot. avgEntry is never buffered — the clamp already keeps
///      the boundary on the correct side of it.
///
///      One step always suffices: rungs are 2.5% apart, so a single step clears
///      the 0.5% buffer with margin. The immediate trade fires on exactly the
///      buffer breach — which is why GROWTH/DECAY are conditional while the
///      per-round budget draw is not.
///
///      Each side is a SINGLE concentrated range spanning six rungs
///      (LadderProxy ships one strategy), so the bounds are:
///        buy  band  = [rl - 5, rl]
///        sell band  = [rh, rh + 5]
library Placement {
    /// @dev Buffer is 0.5% = 50 bps.
    uint256 internal constant BUFFER_BPS = 50;
    uint256 internal constant BPS = 10_000;

    struct Bands {
        uint256 buyLowRung; // rl - 5
        uint256 buyHighRung; // rl (post-bump); band top
        bool doGrowthBuy; // buffer breached: spot-buy GROWTH_PCT, band stepped down
        uint256 sellLowRung; // rh (post-bump); band bottom
        uint256 sellHighRung; // rh + 5
        bool doDecaySell; // buffer breached: spot-sell DECAY_PCT, band stepped up
    }

    /// @param anchor Ladder anchor (rung-1000 price), WAD.
    /// @param spotWad Current spot, WAD USDC/WETH.
    /// @param avgEntryWad Average entry, WAD; 0 when inventory is empty (the
    ///        avgEntry clamp is then dropped and both sides track spot).
    function compute(uint256 anchor, uint256 spotWad, uint256 avgEntryWad)
        internal
        pure
        returns (Bands memory b)
    {
        // ---- BUY: clamp to the cheaper anchor, then buffer against spot ----
        uint256 rl = RungMath.rungBelow(anchor, spotWad);
        if (avgEntryWad != 0) {
            uint256 rlEntry = RungMath.rungBelow(anchor, avgEntryWad);
            if (rlEntry < rl) rl = rlEntry;
        }
        // Band top within 0.5% below spot -> step down one rung and fire GROWTH.
        if (RungMath.priceAt(anchor, rl) * BPS > spotWad * (BPS - BUFFER_BPS)) {
            b.doGrowthBuy = true;
            rl -= 1;
        }
        b.buyHighRung = rl;
        b.buyLowRung = rl - 5;

        // ---- SELL: clamp to the dearer anchor, then buffer against spot ----
        uint256 rh = RungMath.rungAbove(anchor, spotWad);
        if (avgEntryWad != 0) {
            uint256 rhEntry = RungMath.rungAbove(anchor, avgEntryWad);
            if (rhEntry > rh) rh = rhEntry;
        }
        // Band bottom within 0.5% above spot -> step up one rung and fire DECAY.
        if (RungMath.priceAt(anchor, rh) * BPS < spotWad * (BPS + BUFFER_BPS)) {
            b.doDecaySell = true;
            rh += 1;
        }
        b.sellLowRung = rh;
        b.sellHighRung = rh + 5;
    }
}
