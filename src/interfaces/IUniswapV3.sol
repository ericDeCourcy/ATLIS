// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Uniswap v3 SwapRouter02 (Base: 0x2626664c2603336E57B271c5C0b26F421741e481).
/// @dev The '02' router carries no deadline field, unlike the original router.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice Uniswap v3 QuoterV2. Used to SIMULATE a swap before executing it so
///         the quoted execution price — not spot — is what gates the trade.
/// @dev Not a view: it reverts internally and bubbles the result, so call it
///      via staticcall (or eth_call off-chain). Never rely on it inside a state
///      transition where reverting is unacceptable.
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );
}
