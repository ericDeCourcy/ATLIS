// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RungMath} from "./lib/RungMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RungRegistry
/// @notice Stateful companion to RungMath. Caches rung prices and records the
///         buy/sell proxy that starts at each rung.
contract RungRegistry is Ownable {
    /// @notice Rung-1000 price, WAD. Fixed at deployment.
    uint256 public immutable anchor;

    /// @notice rung => price (WAD). Zero means not yet cached.
    mapping(uint256 => uint256) public priceOf;

    /// @notice Bounds of the cached band. INVARIANT: every rung in
    ///         [loCached, hiCached] has a price stored in priceOf.
    uint256 public loCached;
    uint256 public hiCached;

    /// @notice rung => proxy starting at that rung.
    mapping(uint256 => address) public buyProxyAt;
    mapping(uint256 => address) public sellProxyAt;

    event PriceCached(uint256 rung, uint256 price);
    event ProxySet(uint256 rung, bool isBuy, address proxy);

    constructor(uint256 _anchor) Ownable(msg.sender) {
        require(_anchor > 0, "anchor=0");
        anchor = _anchor;
        loCached = RungMath.BASE_RUNG;
        hiCached = RungMath.BASE_RUNG;
        _cache(RungMath.BASE_RUNG, _anchor);
    }

    /*//////////////////////////////////////////////////////////////
                                PRICES
    //////////////////////////////////////////////////////////////*/

    /// @notice Cached price of `rung`, extending the cached band if needed.
    /// @dev Rungs inside [loCached, hiCached] are always present, so a miss can
    ///      only be outside the band. Extends from the nearer edge, storing
    ///      every rung passed to keep the band contiguous. Costs one SSTORE per
    ///      rung extended; a distant first query is therefore expensive, while
    ///      repeated nearby queries are one step each.
    function getPrice(uint256 rung) public returns (uint256 p) {
        if (rung >= loCached && rung <= hiCached) return priceOf[rung];

        if (rung > hiCached) {
            p = priceOf[hiCached];
            for (uint256 n = hiCached; n < rung; ) {
                p = RungMath.stepUp(p);
                unchecked { ++n; }
                _cache(n, p);
            }
            hiCached = rung;
        } else {
            p = priceOf[loCached];
            for (uint256 n = loCached; n > rung; ) {
                p = RungMath.stepDown(p);
                unchecked { --n; }
                _cache(n, p);
            }
            loCached = rung;
        }
    }

    function _cache(uint256 rung, uint256 price) private {
        priceOf[rung] = price;
        emit PriceCached(rung, price);
    }

    /*//////////////////////////////////////////////////////////////
                               PROXIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Records the proxy that starts at `rung`.
    /// @param isBuy true for the buy side, false for the sell side.
    function setAddress(uint256 rung, bool isBuy, address proxy) external onlyOwner {
        require(proxy != address(0), "proxy=0");
        if (isBuy) {
            buyProxyAt[rung] = proxy;
        } else {
            sellProxyAt[rung] = proxy;
        }
        emit ProxySet(rung, isBuy, proxy);
    }
}
