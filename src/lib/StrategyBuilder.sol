// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StrategyBuilder
/// @notice Builds the `strategy` argument for `Aqua.ship` from a fixed template.
///
/// @dev Derived by diffing seven strategies shipped on Base. Across all of
///      them only three regions vary: the two sqrt prices and the salt.
///      Everything else — the tx-origin guard, the Aqua protocol fee and its
///      recipient, the flat fee, the swap step, and every opcode and length
///      byte — is byte-identical. USDC and USDT programs differ only in salt,
///      confirming the token pair is carried by `ship`'s tokens[] array and
///      not by the program.
///
///      Full layout, 132 bytes:
///        [  0: 50]  HEAD   guard + protocol fee + concentrate header
///        [ 50: 82]  sqrtPriceMin
///        [ 82:114]  sqrtPriceMax
///        [114:124]  TAIL   flat fee + swap + salt header
///        [124:132]  salt
///
///      The outer wrapper is `abi.encode(Strategy)`, which Aqua hashes whole.
library StrategyBuilder {
    /// @dev App-specific struct. Aqua treats it as opaque bytes and only hashes
    ///      it; the router decodes it at its calldata boundary.
    struct Strategy {
        address maker;
        uint256 traits;
        bytes program;
    }

    uint256 internal constant TRAITS = 1 << 254;

    /// @dev onlyTxOriginTokenBalanceNonZero(0x26ff..a468),
    ///      aquaProtocolFeeAmountInXD(125000, 0x8063..614a),
    ///      then the concentrate opcode and its 0x40 length byte.
    bytes internal constant HEAD =
        hex"211426ffc7d378e8e49be2c483295a3e3e511f96a468"
        hex"1c180001e8488063d4faf54bf8c898dc6ddc689c76ab12b4614a"
        hex"1240";

    /// @dev flatFeeAmountInXD(500000), xycSwapXD(), then the salt header.
    bytes internal constant TAIL = hex"15040007a12011001408";

    error BadPriceBounds();

    /// @notice Encode a strategy for `maker` covering [`sqrtMin`, `sqrtMax`].
    function build(address maker, uint256 sqrtMin, uint256 sqrtMax, uint64 salt)
        internal
        pure
        returns (bytes memory)
    {
        if (sqrtMin == 0 || sqrtMin >= sqrtMax) revert BadPriceBounds();
        return abi.encode(
            Strategy(maker, TRAITS, abi.encodePacked(HEAD, sqrtMin, sqrtMax, TAIL, salt))
        );
    }
}
