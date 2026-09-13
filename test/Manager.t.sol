// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Manager} from "../src/Manager.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev Exposes the internal booking helpers for direct unit testing.
contract Harness is Manager {
    constructor(Config memory c) Manager(c) {}

    function bookBuys(uint256 usdcSpent, uint256 wethBought) external {
        _bookBuys(usdcSpent, wethBought);
    }

    function bookSells(uint256 wethSold, uint256 usdcReceived) external {
        _bookSells(wethSold, usdcReceived);
    }
}

contract ManagerAccountingTest is Test {
    Harness mgr;
    MockERC20 usdc;
    MockERC20 weth;

    address profitDest = makeAddr("profit");
    address taxDest = makeAddr("tax");

    uint256 constant TAX_BPS = 3000; // 30%

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        Manager.Config memory c = Manager.Config({
            aqua: makeAddr("aqua"),
            aquaApp: makeAddr("aquaApp"),
            usdc: address(usdc),
            weth: address(weth),
            anchor: 3000e18,
            priceFeed: makeAddr("feed"),
            swapRouter: makeAddr("router"),
            quoter: makeAddr("quoter"),
            poolFee: 100,
            rebalancePeriod: 1 days,
            newPowderPerPeriod: 100e6,
            purchPct: 5000,
            growthPct: 5000,
            decayPct: 5000,
            minBuy: 10e6,
            minSell: 1e15,
            taxPct: TAX_BPS,
            profitDest: profitDest,
            taxDest: taxDest,
            slippageBps: 50,
            maxStaleness: 3600
        });
        mgr = new Harness(c);
    }

    // ---- BUYS ----------------------------------------------------------

    function test_bookBuys_singleSetsAvgToFillPrice() public {
        mgr.bookBuys(3000e6, 1e18); // 1 WETH @ 3000
        assertEq(mgr.costBasisUsdc(), 3000e6);
        assertEq(mgr.inventoryWeth(), 1e18);
        assertEq(mgr.avgEntryWad(), 3000e18);
    }

    function test_bookBuys_twoFillsWeightedAvg() public {
        mgr.bookBuys(3000e6, 1e18); // @3000
        mgr.bookBuys(2000e6, 1e18); // @2000
        assertEq(mgr.costBasisUsdc(), 5000e6);
        assertEq(mgr.inventoryWeth(), 2e18);
        assertEq(mgr.avgEntryWad(), 2500e18, "weighted avg of 3000 and 2000");
    }

    // ---- SELLS ---------------------------------------------------------

    /// The user's worked trace: 1 WETH bought at $1000, sold at $1500.
    /// $500 profit, 30% tax -> $150 to tax, $350 to profit, $1000 principal
    /// retained in the Manager balance. Inventory and basis fully zeroed.
    function test_bookSells_userTrace_fullExitWithProfit() public {
        mgr.bookBuys(1000e6, 1e18);
        // Proceeds land in the Manager before booking (simulating swept USDC).
        usdc.mint(address(mgr), 1500e6);

        mgr.bookSells(1e18, 1500e6);

        assertEq(usdc.balanceOf(taxDest), 150e6, "30% of 500 profit");
        assertEq(usdc.balanceOf(profitDest), 350e6, "net profit swept");
        assertEq(usdc.balanceOf(address(mgr)), 1000e6, "principal retained for the drip");
        assertEq(mgr.inventoryWeth(), 0);
        assertEq(mgr.costBasisUsdc(), 0);
        assertEq(mgr.avgEntryWad(), 0);
    }

    /// Partial sell: proportional slice removed, avgEntry unchanged.
    function test_bookSells_partialLeavesAvgUnchanged() public {
        mgr.bookBuys(4000e6, 2e18); // avg 2000
        usdc.mint(address(mgr), 3000e6);

        mgr.bookSells(1e18, 3000e6); // sell 1 of 2 WETH for 3000

        assertEq(mgr.inventoryWeth(), 1e18);
        assertEq(mgr.costBasisUsdc(), 2000e6, "half the basis removed");
        assertEq(mgr.avgEntryWad(), 2000e18, "avg unchanged by a sell");

        assertEq(usdc.balanceOf(taxDest), 300e6, "30% of 1000 profit");
        assertEq(usdc.balanceOf(profitDest), 700e6);
        assertEq(usdc.balanceOf(address(mgr)), 2000e6, "principal retained");
    }

    /// Loss-making sell: basis reduced, nothing swept.
    function test_bookSells_atLossSweepsNothing() public {
        mgr.bookBuys(3000e6, 1e18);
        usdc.mint(address(mgr), 2000e6);

        mgr.bookSells(1e18, 2000e6);

        assertEq(mgr.inventoryWeth(), 0);
        assertEq(mgr.costBasisUsdc(), 0);
        assertEq(usdc.balanceOf(taxDest), 0);
        assertEq(usdc.balanceOf(profitDest), 0);
        assertEq(usdc.balanceOf(address(mgr)), 2000e6, "all proceeds retained");
    }

    /// Over-sell (rounding safety): selling >= inventory zeroes cleanly.
    function test_bookSells_overSellZeroesCleanly() public {
        mgr.bookBuys(1000e6, 1e18);
        usdc.mint(address(mgr), 1200e6);
        mgr.bookSells(2e18, 1200e6); // ask to sell more than held
        assertEq(mgr.inventoryWeth(), 0);
        assertEq(mgr.costBasisUsdc(), 0);
    }
}
