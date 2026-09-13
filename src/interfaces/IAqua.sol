// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Signatures taken verbatim from 1inch/aqua src/Aqua.sol.
interface IAqua {
    function ship(
        address app,
        bytes calldata strategy,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external returns (bytes32 strategyHash);

    /// @dev Requires balance.tokensCount == tokens.length for every token, so
    ///      the array must list ALL tokens the strategy was shipped with.
    ///      Sets tokensCount to _DOCKED (0xff), which ship() never accepts —
    ///      the same strategy bytes can never be shipped again.
    function dock(address app, bytes32 strategyHash, address[] calldata tokens) external;

    /// @dev Increases the declared balance by `amount` and transfers `amount`
    ///      from msg.sender to `maker`. No access control on msg.sender; only
    ///      requires the strategy to be active. When msg.sender == maker the
    ///      transfer is a self-transfer and nets to zero tokens moved.
    function push(address maker, address app, bytes32 strategyHash, address token, uint256 amount) external;

    function rawBalances(address maker, address app, bytes32 strategyHash, address token)
        external
        view
        returns (uint248 balance, uint8 tokensCount);
}
