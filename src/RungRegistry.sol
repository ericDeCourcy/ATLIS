// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RungMath} from "./RungMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RungRegistry
/// @notice Stateful companion to RungMath. Caches rung prices and records the
///         buy/sell proxy that starts at each rung.
contract RungRegistry is Ownable {
    /// @notice Rung-1000 price, WAD. Fixed at deployment.
    uint256 public immutable anchor;

    /// @notice rung => price (WAD). Zero means not yet cached.
    mapping(uint256 => uint256) public priceOf;

    /// @notice rung => proxy starting at that rung.
    mapping(uint256 => address) public buyProxyAt;
    mapping(uint256 => address) public sellProxyAt;

    event PriceCached(uint256 rung, uint256 price);
    event ProxySet(uint256 rung, bool isBuy, address proxy);

    constructor(uint256 _anchor) Ownable(msg.sender) {
        require(_anchor > 0, "anchor=0");
        anchor = _anchor;
        _cache(RungMath.BASE_RUNG, _anchor);
    }

    /*//////////////////////////////////////////////////////////////
                                PRICES
    //////////////////////////////////////////////////////////////*/

    /// @notice Cached price of `rung`, computing and storing it if absent.
    function getPrice(uint256 rung) public returns (uint256 p) {
        p = priceOf[rung];
        if (p == 0) {
            p = RungMath.priceAt(anchor, rung);
            _cache(rung, p);
        }
    }

    /// @notice Price of the rung above `rung`, stepped from its cached value.
    /// @dev Steps only when `rung` is already cached; otherwise falls back to
    ///      priceAt so drift never compounds from an uncached start.
    function priceAbove(uint256 rung) external returns (uint256 p) {
        uint256 next = rung + 1;
        p = priceOf[next];
        if (p != 0) return p;

        uint256 cur = priceOf[rung];
        p = cur == 0 ? RungMath.priceAt(anchor, next) : RungMath.stepUp(cur);
        _cache(next, p);
    }

    /// @notice Price of the rung below `rung`, stepped from its cached value.
    function priceBelow(uint256 rung) external returns (uint256 p) {
        require(rung > 0, "rung=0");
        uint256 prev = rung - 1;
        p = priceOf[prev];
        if (p != 0) return p;

        uint256 cur = priceOf[rung];
        p = cur == 0 ? RungMath.priceAt(anchor, prev) : RungMath.stepDown(cur);
        _cache(prev, p);
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
