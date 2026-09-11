// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RungMath} from "../src/lib/RungMath.sol";
import {RungRegistry} from "../src/RungRegistry.sol";

contract RungRegistryTest is Test {
    uint256 constant ANCHOR = 3000e18;
    uint256 constant BASE = RungMath.BASE_RUNG;

    RungRegistry registry;
    address stranger = address(0xBEEF);
    address proxy = address(0xCAFE);

    function setUp() public {
        registry = new RungRegistry(ANCHOR);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_anchorStored() public view {
        assertEq(registry.anchor(), ANCHOR);
    }

    function test_anchorRungCachedOnDeploy() public view {
        assertEq(registry.priceOf(BASE), ANCHOR);
    }

    function test_revertsOnZeroAnchor() public {
        vm.expectRevert(bytes("anchor=0"));
        new RungRegistry(0);
    }

    /*//////////////////////////////////////////////////////////////
                              GET PRICE
    //////////////////////////////////////////////////////////////*/

    function test_getPrice_cachesOnMiss() public {
        assertEq(registry.priceOf(BASE + 5), 0);

        uint256 p = registry.getPrice(BASE + 5);

        assertEq(p, RungMath.priceAt(ANCHOR, BASE + 5));
        assertEq(registry.priceOf(BASE + 5), p);
    }

    function test_getPrice_stableAcrossCalls() public {
        assertEq(registry.getPrice(BASE + 3), registry.getPrice(BASE + 3));
    }

    /*//////////////////////////////////////////////////////////////
        STEPPING
        Since priceAt is the iterated walk, a stepped value must equal
        the canonical one EXACTLY. This is what makes the cache safe.
    //////////////////////////////////////////////////////////////*/

    function test_priceAbove_stepsFromCachedNeighbour() public {
        uint256 p = registry.priceAbove(BASE); // BASE cached at deploy
        assertEq(p, RungMath.stepUp(ANCHOR));
        assertEq(p, RungMath.priceAt(ANCHOR, BASE + 1));
        assertEq(registry.priceOf(BASE + 1), p);
    }

    function test_priceBelow_stepsFromCachedNeighbour() public {
        uint256 p = registry.priceBelow(BASE);
        assertEq(p, RungMath.stepDown(ANCHOR));
        assertEq(p, RungMath.priceAt(ANCHOR, BASE - 1));
        assertEq(registry.priceOf(BASE - 1), p);
    }

    /// @dev Cold start uses the exact path rather than stepping from nothing.
    function test_priceAbove_coldFallsBackToExact() public {
        uint256 cold = BASE + 40;
        assertEq(registry.priceOf(cold), 0);
        assertEq(registry.priceAbove(cold), RungMath.priceAt(ANCHOR, cold + 1));
    }

    function test_priceBelow_coldFallsBackToExact() public {
        uint256 cold = BASE - 40;
        assertEq(registry.priceOf(cold), 0);
        assertEq(registry.priceBelow(cold), RungMath.priceAt(ANCHOR, cold - 1));
    }

    function test_priceAbove_returnsExistingCache() public {
        uint256 seeded = registry.getPrice(BASE + 1);
        assertEq(registry.priceAbove(BASE), seeded);
    }

    /// @dev Walking up rung by rung must match priceAt at every step.
    function test_walkUp_matchesCanonical() public {
        for (uint256 i = 0; i < 25; i++) {
            uint256 p = registry.priceAbove(BASE + i);
            assertEq(p, RungMath.priceAt(ANCHOR, BASE + i + 1));
        }
    }

    function test_walkDown_matchesCanonical() public {
        for (uint256 i = 0; i < 25; i++) {
            uint256 p = registry.priceBelow(BASE - i);
            assertEq(p, RungMath.priceAt(ANCHOR, BASE - i - 1));
        }
    }

    /// @dev Reaching a rung by walking and by cold lookup must agree.
    function test_walkedAndColdAgree() public {
        RungRegistry cold = new RungRegistry(ANCHOR);
        uint256 target = BASE + 10;

        for (uint256 i = 0; i < 10; i++) {
            registry.priceAbove(BASE + i);
        }

        assertEq(registry.priceOf(target), cold.getPrice(target));
    }

    function test_priceBelow_revertsAtZero() public {
        vm.expectRevert(bytes("rung=0"));
        registry.priceBelow(0);
    }

    /*//////////////////////////////////////////////////////////////
                            PROXY REGISTRY
    //////////////////////////////////////////////////////////////*/

    function test_setAddress_buy() public {
        registry.setAddress(BASE - 1, true, proxy);
        assertEq(registry.buyProxyAt(BASE - 1), proxy);
        assertEq(registry.sellProxyAt(BASE - 1), address(0));
    }

    function test_setAddress_sell() public {
        registry.setAddress(BASE + 2, false, proxy);
        assertEq(registry.sellProxyAt(BASE + 2), proxy);
        assertEq(registry.buyProxyAt(BASE + 2), address(0));
    }

    /// @dev Both sides may register at the same rung independently.
    function test_setAddress_sidesIndependent() public {
        registry.setAddress(BASE, true, address(0xA1));
        registry.setAddress(BASE, false, address(0xB2));

        assertEq(registry.buyProxyAt(BASE), address(0xA1));
        assertEq(registry.sellProxyAt(BASE), address(0xB2));
    }

    function test_setAddress_overwrites() public {
        registry.setAddress(BASE, true, proxy);
        registry.setAddress(BASE, true, address(0xD00D));
        assertEq(registry.buyProxyAt(BASE), address(0xD00D));
    }

    function test_setAddress_revertsOnZero() public {
        vm.expectRevert(bytes("proxy=0"));
        registry.setAddress(BASE, true, address(0));
    }

    function test_setAddress_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        registry.setAddress(BASE, true, proxy);
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Every cached price must equal the canonical computation.
    function test_cacheMatchesCanonical() public {
        for (uint256 n = BASE - 6; n <= BASE + 6; n++) {
            registry.getPrice(n);
        }
        for (uint256 n = BASE - 6; n <= BASE + 6; n++) {
            assertEq(registry.priceOf(n), RungMath.priceAt(ANCHOR, n));
        }
    }

    function test_cachedPricesMonotonic() public {
        uint256 prev;
        for (uint256 n = BASE - 6; n <= BASE + 6; n++) {
            uint256 p = registry.getPrice(n);
            if (prev != 0) assertGt(p, prev);
            prev = p;
        }
    }

    function testFuzz_cacheMatchesCanonical(uint16 n) public {
        uint256 rung = bound(n, BASE - 60, BASE + 60);
        assertEq(registry.getPrice(rung), RungMath.priceAt(ANCHOR, rung));
    }
}
