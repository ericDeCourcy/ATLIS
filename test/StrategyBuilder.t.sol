// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StrategyBuilder} from "../src/lib/StrategyBuilder.sol";
import {AquaPriceMath} from "../src/lib/AquaPriceMath.sol";

/// @notice Byte-for-byte parity against every strategy shipped on Base.
contract StrategyBuilderTest is Test {
    address constant MAKER = 0x1234567890123456789012345678901234567890;
                               

    function _ref(bytes memory tail) private pure returns (bytes memory) {
        return abi.encodePacked(
            hex"0000000000000000000000000000000000000000000000000000000000000020"
            hex"0000000000000000000000001234567890123456789012345678901234567890"
            hex"4000000000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000060"
            hex"0000000000000000000000000000000000000000000000000000000000000084"
            hex"211426ffc7d378e8e49be2c483295a3e3e511f96a468"
            hex"1c180001e8488063d4faf54bf8c898dc6ddc689c76ab12b4614a"
            hex"1240",
            tail,
            hex"00000000000000000000000000000000000000000000000000000000"
        );
    }

    function _check(uint256 lo, uint256 hi, uint64 salt, bytes memory tail) private pure {
        assertEq(StrategyBuilder.build(MAKER, lo, hi, salt), _ref(tail));
    }

    /*//////////////////////////////////////////////////////////////
        Each case is a real shipped strategy. The tail is the exact
        on-chain bytes from sqrtPriceMin through the salt.
    //////////////////////////////////////////////////////////////*/

    function test_range2500to3000_usdc() public pure {
        _check(
            0x2d79883d2000,
            0x31d0a8d8f974,
            0xd45f070680bb4f27,
            hex"00000000000000000000000000000000000000000000000000002d79883d2000"
            hex"000000000000000000000000000000000000000000000000000031d0a8d8f974"
            hex"15040007a12011001408d45f070680bb4f27"
        );
    }

    function test_range3000to4000_usdc() public pure {
        _check(
            0x31d0a8d8f974,
            0x398580bb78a7,
            0x8a20ea2dcf9d3092,
            hex"000000000000000000000000000000000000000000000000000031d0a8d8f974"
            hex"0000000000000000000000000000000000000000000000000000398580bb78a7"
            hex"15040007a12011001408" hex"8a20ea2dcf9d3092"
        );
    }

    function test_range3000to3001_usdc() public pure {
        _check(
            0x31d0a8d8f974,
            0x31d2c8ea6b09,
            0xa6d0c24effa095da,
            hex"000000000000000000000000000000000000000000000000000031d0a8d8f974"
            hex"000000000000000000000000000000000000000000000000000031d2c8ea6b09"
            hex"15040007a12011001408" hex"a6d0c24effa095da"
        );
    }

    /// @dev USDT, not USDC — yet the program is identical apart from the salt.
    ///      The token pair lives in ship()'s tokens[] array, not the program.
    function test_range3000to4000_usdt() public pure {
        _check(
            0x31d0a8d8f974,
            0x398580bb78a7,
            0x66da78cbacf1ed27,
            hex"000000000000000000000000000000000000000000000000000031d0a8d8f974"
            hex"0000000000000000000000000000000000000000000000000000398580bb78a7"
            hex"15040007a12011001408" hex"66da78cbacf1ed27"
        );
    }

    function test_range3000to4000_thirdSalt() public pure {
        _check(
            0x31d0a8d8f974,
            0x398580bb78a7,
            0xd448da8889f8d3c9,
            hex"000000000000000000000000000000000000000000000000000031d0a8d8f974"
            hex"0000000000000000000000000000000000000000000000000000398580bb78a7"
            hex"15040007a12011001408" hex"d448da8889f8d3c9"
        );
    }

    function test_range3000to3001_usdt() public pure {
        _check(
            0x31d0a8d8f974,
            0x31d2c8ea6b09,
            0xa6d0c24effa095db,
            hex"000000000000000000000000000000000000000000000000000031d0a8d8f974"
            hex"000000000000000000000000000000000000000000000000000031d2c8ea6b09"
            hex"15040007a12011001408" hex"a6d0c24effa095db"
        );
    }

    /// @dev A buy-side position: the whole band sits below spot.
    function test_range1500to2000_usdc() public pure {
        _check(
            0x23397df7393a,
            0x28ac80bff62b,
            0xb1e74409a9e1c727,
            hex"000000000000000000000000000000000000000000000000000023397df7393a"
            hex"000000000000000000000000000000000000000000000000000028ac80bff62b"
            hex"15040007a12011001408" hex"b1e74409a9e1c727"
        );
    }

    /*//////////////////////////////////////////////////////////////
                              PROPERTIES
    //////////////////////////////////////////////////////////////*/

    function test_lengthIsConstant() public pure {
        assertEq(StrategyBuilder.build(MAKER, 1, 2, 0).length, 320);
    }

    /// @dev The maker is the proxy, and it is inside the hashed bytes — so two
    ///      proxies shipping the same range and salt get different hashes.
    function test_makerAffectsHash() public pure {
        assertTrue(
            keccak256(StrategyBuilder.build(MAKER, 0x2d79883d2000, 0x31d0a8d8f974, 1))
                != keccak256(
                    StrategyBuilder.build(address(0xBEEF), 0x2d79883d2000, 0x31d0a8d8f974, 1)
                )
        );
    }

    function testFuzz_saltChangesHash(uint64 a, uint64 b) public pure {
        vm.assume(a != b);
        assertTrue(
            keccak256(StrategyBuilder.build(MAKER, 1, 2, a))
                != keccak256(StrategyBuilder.build(MAKER, 1, 2, b))
        );
    }

    function test_revertsOnZeroMin() public {
        vm.expectRevert(StrategyBuilder.BadPriceBounds.selector);
        this.buildExt(0, 1, 0);
    }

    function test_revertsOnInvertedBounds() public {
        vm.expectRevert(StrategyBuilder.BadPriceBounds.selector);
        this.buildExt(2, 1, 0);
    }

    function buildExt(uint256 lo, uint256 hi, uint64 s) external pure {
        StrategyBuilder.build(MAKER, lo, hi, s);
    }

    /// @dev End to end from human prices through to on-chain bytes.
    function test_endToEnd_humanPrices() public pure {
        _check(
            AquaPriceMath.toSqrtPriceUsdcWeth(2500e18),
            AquaPriceMath.toSqrtPriceUsdcWeth(3000e18),
            0xd45f070680bb4f27,
            hex"00000000000000000000000000000000000000000000000000002d79883d2000"
            hex"000000000000000000000000000000000000000000000000000031d0a8d8f974"
            hex"15040007a12011001408d45f070680bb4f27"
        );
    }
}
