// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SaltLib
/// @notice Derives the `Salt` instruction value for an ATLIS strategy.
///
/// @dev WHY A SALT IS REQUIRED
///      Aqua computes `strategyHash = keccak256(strategy)` from the program
///      bytes alone — no maker, no nonce. `dock` then sets the balance slot's
///      tokensCount to _DOCKED (0xff), and `ship` only accepts 0, so a docked
///      strategy's exact bytes can NEVER be shipped again by that maker.
///
///      Every ship of a given rung range would otherwise produce identical
///      bytes, making the range single-use for the lifetime of the proxy. The
///      Salt instruction exists solely to break that: it has no runtime effect
///      (`Salt.exec` is empty) and only perturbs the hash.
///
/// @dev SCHEME
///      salt = uint64(keccak256(chainId, proxy, nonce))
///
///      - nonce   proxy-local, monotonic, never reused. This alone guarantees
///                uniqueness for a given proxy across all time.
///      - proxy   keeps salts distinct between proxies at the same nonce.
///      - chainId prevents identical salts across chains where the same proxy
///                address may be deployed.
///
///      No timestamp. With a monotonic per-proxy nonce it would add nothing to
///      uniqueness, and it would make the salt impossible to reproduce
///      off-chain without reading block data.
///
/// @dev COLLISION EXPOSURE
///      The Salt instruction carries a uint64 (8 bytes, per `Salt.sizeOf`), so
///      the keccak output is truncated to 64 bits. A collision only matters for
///      the SAME maker and app — `_balances` is keyed
///      [maker][app][strategyHash][token], so identical bytes from two
///      different proxies occupy different slots and cannot conflict. Within a
///      single proxy the birthday bound is ~2^32 strategies, far beyond any
///      realistic lifetime, and a collision fails loudly (ship reverts with
///      StrategiesMustBeImmutable) rather than corrupting state.
library SaltLib {
    /// @notice Derive a salt for `proxy` at `nonce`, on the current chain.
    function compute(address proxy, uint256 nonce) internal view returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(block.chainid, proxy, nonce))));
    }

    /// @notice Derive a salt using an explicit chain id.
    /// @dev Pure variant, for off-chain derivation and cross-chain testing.
    function computeWithChainId(uint256 chainId, address proxy, uint256 nonce)
        internal
        pure
        returns (uint64)
    {
        return uint64(uint256(keccak256(abi.encode(chainId, proxy, nonce))));
    }
}
