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

    /// @notice Lowest and highest rungs ever cached. Both are always present in
    ///         priceOf, so either is a valid starting point for a walk. The
    ///         band between them is not necessarily fully populated.
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

    /// @notice Cached price of `rung`, computing and storing it if absent.
    /// @dev Walks from the nearest cached rung rather than always from the
    ///      anchor. Only the target is stored — caching intermediates would
    ///      cost an SSTORE per rung, far more than the steps it saves.
    function getPrice(uint256 rung) public returns (uint256 p) {
        p = priceOf[rung];
        if (p != 0) return p;

        uint256 from = rung > hiCached ? hiCached : (rung < loCached ? loCached : RungMath.BASE_RUNG);
        p = RungMath.priceFrom(from, priceOf[from], rung);

        if (rung > hiCached) hiCached = rung;
        else if (rung < loCached) loCached = rung;
        _cache(rung, p);
    }

    /// @notice Price of the rung above `rung`.
    function priceAbove(uint256 rung) external returns (uint256) {
        return getPrice(rung + 1);
    }

    /// @notice Price of the rung below `rung`.
    function priceBelow(uint256 rung) external returns (uint256) {
        require(rung > 0, "rung=0");
        return getPrice(rung - 1);
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
