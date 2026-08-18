// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest} from "./FrameTest.sol";

interface ISetDelegateHarness {
    function setDelegate(bytes32 salt, address target) external returns (address);
    function clearDelegate(bytes32 salt) external returns (address);
    function computeDelegateAddress(address deployer, bytes32 salt) external pure returns (address);
}

/// SetDelegateLib compiles only with the patched solc, so the harness runtime
/// is etched from out-frame like the frame-glue accounts. The SETDELEGATE
/// opcode itself is gated behind an EVM configuration bit that only Anvil
/// exposes (`--enable-eip7819`); in this test EVM the wrapper must halt, and
/// the address derivation -- plain EVM code -- must work.
contract SetDelegateLibTest is FrameTest {
    ISetDelegateHarness harness;

    function setUp() public {
        harness = ISetDelegateHarness(deployAccount("SetDelegateLibHarness", address(0xde1e6a7e)));
    }

    function test_computeDelegateAddress_matchesGoldenVector() public view {
        // keccak256(0xef0100 ++ 0x11..11 ++ 0x22..22)
        //   = 0x2542be69168a72afd65fbf3df1edb9ac342efdb1d5138c0de10bce93f5512f65
        assertEq(
            harness.computeDelegateAddress(
                0x1111111111111111111111111111111111111111,
                0x2222222222222222222222222222222222222222222222222222222222222222
            ),
            0xf1eDb9ac342EFDB1d5138C0DE10bCE93F5512F65
        );
    }

    function test_computeDelegateAddress_dependsOnDeployerAndSalt() public view {
        address a = harness.computeDelegateAddress(address(0xA), bytes32(uint256(1)));
        assertTrue(a != harness.computeDelegateAddress(address(0xB), bytes32(uint256(1))));
        assertTrue(a != harness.computeDelegateAddress(address(0xA), bytes32(uint256(2))));
    }

    function test_setDelegate_haltsWhileEip7819Disabled() public {
        (bool ok,) = address(harness)
            .call(abi.encodeCall(ISetDelegateHarness.setDelegate, (bytes32(0), address(0xBEEF))));
        assertFalse(ok);
    }

    function test_clearDelegate_haltsWhileEip7819Disabled() public {
        (bool ok,) =
            address(harness).call(abi.encodeCall(ISetDelegateHarness.clearDelegate, (bytes32(0))));
        assertFalse(ok);
    }
}
