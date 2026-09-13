// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Placement} from "../src/lib/Placement.sol";
import {RungMath} from "../src/lib/RungMath.sol";

contract PlacementTest is Test {
    uint256 constant ANCHOR = 3000e18; // rung 1000 = 3000 USDC/WETH
    // rung 1001 = 3075, rung 999 = 2925, etc.

    function _compute(uint256 spot, uint256 avg) internal pure returns (Placement.Bands memory) {
        return Placement.compute(ANCHOR, spot, avg);
    }

    /// Spot sitting exactly on rung 1000: both boundaries are within 0.5% of
    /// spot, so both trades fire and both bands step one rung away.
    function test_spotOnRung_bothTradesFire() public pure {
        Placement.Bands memory b = _compute(3000e18, 3000e18);

        assertTrue(b.doGrowthBuy, "growth should fire");
        assertEq(b.buyHighRung, 999, "buy top stepped down to 999");
        assertEq(b.buyLowRung, 994, "buy bottom = top - 5");

        assertTrue(b.doDecaySell, "decay should fire");
        assertEq(b.sellLowRung, 1001, "sell bottom stepped up to 1001");
        assertEq(b.sellHighRung, 1006, "sell top = bottom + 5");
    }

    /// Spot comfortably between rungs (3040, between 3000 and 3075): neither
    /// boundary is within 0.5%, so no immediate trade and no bump.
    function test_spotBetweenRungs_noTrade() public pure {
        Placement.Bands memory b = _compute(3040e18, 3040e18);

        assertFalse(b.doGrowthBuy, "no growth");
        assertEq(b.buyHighRung, 1000, "buy top = rungBelow(spot)");
        assertEq(b.buyLowRung, 995);

        assertFalse(b.doDecaySell, "no decay");
        assertEq(b.sellLowRung, 1001, "sell bottom = rungAbove(spot)");
        assertEq(b.sellHighRung, 1006);
    }

    /// In profit (spot >> avgEntry): buys track avgEntry (cheaper), sells track
    /// spot. Buy side parks far below and stays inert (no growth trade).
    function test_inProfit_buyTracksEntry_sellTracksSpot() public pure {
        uint256 spot = 3040e18;
        uint256 avg = 2500e18;
        Placement.Bands memory b = _compute(spot, avg);

        uint256 rlEntry = RungMath.rungBelow(ANCHOR, avg);
        assertEq(b.buyHighRung, rlEntry, "buy top clamps to avgEntry rung");
        assertFalse(b.doGrowthBuy, "buy parked far from spot: inert");

        assertEq(b.sellLowRung, 1001, "sell tracks spot (rungAbove 3040)");
    }

    /// Underwater (spot << avgEntry): buys track spot, sells track avgEntry and
    /// park far above (no decay trade near spot).
    function test_underwater_buyTracksSpot_sellTracksEntry() public pure {
        uint256 spot = 2500e18;
        uint256 avg = 3040e18;
        Placement.Bands memory b = _compute(spot, avg);

        assertEq(b.buyHighRung, RungMath.rungBelow(ANCHOR, spot), "buy tracks spot");

        uint256 rhEntry = RungMath.rungAbove(ANCHOR, avg);
        assertEq(b.sellLowRung, rhEntry, "sell top clamps to avgEntry rung");
        assertFalse(b.doDecaySell, "sell parked far from spot: inert");
    }

    /// Zero inventory (avgEntry == 0): the avgEntry clamp is dropped and both
    /// sides track spot alone.
    function test_zeroInventory_tracksSpotOnly() public pure {
        Placement.Bands memory b = _compute(3040e18, 0);
        assertEq(b.buyHighRung, 1000);
        assertEq(b.sellLowRung, 1001);
    }

    /// Bands are always six rungs wide and correctly ordered for LadderProxy
    /// (low < high), across a spread of spot values.
    function testFuzz_bandsWellFormed(uint256 spot) public pure {
        spot = bound(spot, 1500e18, 6000e18);
        Placement.Bands memory b = _compute(spot, spot);

        assertEq(b.buyHighRung - b.buyLowRung, 5, "buy width 5");
        assertEq(b.sellHighRung - b.sellLowRung, 5, "sell width 5");
        assertLt(b.buyLowRung, b.buyHighRung);
        assertLt(b.sellLowRung, b.sellHighRung);
        assertLt(b.buyHighRung, b.sellLowRung, "buy band strictly below sell band");
    }
}
