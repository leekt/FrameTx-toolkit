// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest} from "./FrameTest.sol";

interface ISelfDelegateHarness {
    function setSelfDelegate(address target) external returns (bool);
    function delegation(address account)
        external
        view
        returns (bool isDelegation, bool ecdsaDisabled, address target);
    function isEcdsaDisabled(address account) external view returns (bool);
}

/// SelfDelegateLib compiles only with the patched solc, so the harness runtime
/// is etched from out-frame. The SETSELFDELEGATE opcode is gated behind an EVM
/// configuration bit only Anvil exposes (`--enable-eip7851`); here the wrapper
/// must halt, and the designator read helpers -- plain EVM code -- must work.
contract SelfDelegateLibTest is FrameTest {
    ISelfDelegateHarness harness;

    address constant TARGET = 0x00000000000000000000000000000000DeaDBeef;

    function setUp() public {
        harness = ISelfDelegateHarness(deployAccount("SelfDelegateLibHarness", address(0x7851)));
    }

    function test_delegation_readsEcdsaEnabledIndicator() public {
        address account = address(0xAA01);
        vm.etch(account, abi.encodePacked(hex"ef0100", TARGET));

        (bool isDelegation, bool disabled, address target) = harness.delegation(account);
        assertTrue(isDelegation);
        assertFalse(disabled);
        assertEq(target, TARGET);
        assertFalse(harness.isEcdsaDisabled(account));
    }

    function test_delegation_readsEcdsaDisabledIndicator() public {
        address account = address(0xAA02);
        vm.etch(account, abi.encodePacked(hex"ef0101", TARGET));

        (bool isDelegation, bool disabled, address target) = harness.delegation(account);
        assertTrue(isDelegation);
        assertTrue(disabled);
        assertEq(target, TARGET);
        assertTrue(harness.isEcdsaDisabled(account));
    }

    function test_delegation_rejectsPlainCodeAndEmptyAccounts() public {
        // The harness itself carries ordinary runtime code.
        (bool isDelegation, bool disabled, address target) = harness.delegation(address(harness));
        assertFalse(isDelegation);
        assertFalse(disabled);
        assertEq(target, address(0));

        (isDelegation,,) = harness.delegation(address(0xAA03)); // empty
        assertFalse(isDelegation);
    }

    function test_delegation_rejects23ByteNonDesignatorCode() public {
        address account = address(0xAA04);
        vm.etch(account, abi.encodePacked(hex"600055", TARGET)); // 23 bytes, no 0xef01 prefix

        (bool isDelegation,,) = harness.delegation(account);
        assertFalse(isDelegation);
    }

    function test_setSelfDelegate_haltsWhileEip7851Disabled() public {
        (bool ok,) =
            address(harness).call(abi.encodeCall(ISelfDelegateHarness.setSelfDelegate, (TARGET)));
        assertFalse(ok);
    }
}
