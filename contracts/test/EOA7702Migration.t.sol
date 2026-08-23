// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccountTestSuite} from "./AccountTestSuite.sol";
import {IFrameVm} from "./FrameTest.sol";
import {EOA7702FrameAccount} from "../src/accounts/EOA7702FrameAccount.sol";
import {Vm} from "forge-std/Vm.sol";

contract EOA7702MigrationTarget {
    uint256 public calls;
    address public lastCaller;

    function ping() external returns (uint256) {
        ++calls;
        lastCaller = msg.sender;
        return calls;
    }
}

/// Exercises a same-address EOA migration with Foundry's real EIP-7702
/// authorization processing. The inherited account suite then drives the
/// delegated runtime through every EIP-8141 account role.
contract EOA7702MigrationTest is AccountTestSuite {
    uint256 internal constant AUTHORITY_KEY = 0x77028141;
    uint256 internal constant STARTING_BALANCE = 3 ether;

    address internal authority;
    EOA7702FrameAccount internal implementation;
    uint64 internal installationAuthorizationNonce;

    function setUp() public {
        authority = vm.addr(AUTHORITY_KEY);
        implementation = new EOA7702FrameAccount();
        vm.deal(authority, STARTING_BALANCE);

        Vm.SignedDelegation memory installation =
            vm.signAndAttachDelegation(address(implementation), AUTHORITY_KEY);
        installationAuthorizationNonce = installation.nonce;
    }

    function accountUnderTest() internal view override returns (address) {
        return authority;
    }

    function accountAuthorizationSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = secpSig(authority);
    }

    function test_eoa7702Migration_preservesAddressBalanceAndExactDelegate() public view {
        assertEq(authority.balance, STARTING_BALANCE, "delegation must not move EOA funds");
        assertEq(authority.code.length, 23, "delegation indicator must be exactly 23 bytes");
        assertEq(
            authority.code,
            abi.encodePacked(hex"ef0100", address(implementation)),
            "authority must delegate to the reviewed Frame implementation"
        );
        assertEq(
            installationAuthorizationNonce,
            0,
            "first authorization must sign the authority's current nonce"
        );
    }

    function test_eoa7702Migration_keepsLegacySelfExecution() public {
        EOA7702MigrationTarget target = new EOA7702MigrationTarget();

        vm.prank(authority);
        bytes memory result = EOA7702FrameAccount(payable(authority))
            .execute(address(target), 0, abi.encodeCall(EOA7702MigrationTarget.ping, ()));

        assertEq(abi.decode(result, (uint256)), 1, "legacy path must return target data");
        assertEq(target.calls(), 1, "legacy EOA-originated call must execute");
        assertEq(target.lastCaller(), authority, "delegated call must preserve EOA identity");
    }

    function test_eoa7702Migration_rejectsThirdPartyLegacyExecution() public {
        EOA7702MigrationTarget target = new EOA7702MigrationTarget();
        vm.expectRevert(EOA7702FrameAccount.NotAuthority.selector);
        EOA7702FrameAccount(payable(authority))
            .execute(address(target), 0, abi.encodeCall(EOA7702MigrationTarget.ping, ()));
        assertEq(target.calls(), 0, "unauthorized caller must not reach the target");
    }

    function test_eoa7702Migration_rejectsCrossSchemeSignerCollision() public {
        IFrameVm.FrameTx memory ctx = verifyContext(authority, SCOPE_BOTH, bytes32(0));
        ctx.frames[0].data = validationCalldata(0);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = p256Sig(authority);
        assertRefusesFrame(
            authority,
            ctx,
            "same-address P256 metadata must not broaden the delegated EOA's secp256k1 root"
        );
    }

    function test_eoa7702Migration_signedClearRestoresPlainEoa() public {
        uint256 balanceBefore = authority.balance;
        Vm.SignedDelegation memory clear = vm.signAndAttachDelegation(address(0), AUTHORITY_KEY);

        assertEq(authority.code.length, 0, "zero-address authorization must clear delegation");
        assertEq(authority.balance, balanceBefore, "clearing delegation must preserve funds");
        assertEq(
            clear.nonce,
            installationAuthorizationNonce + 1,
            "rollback tuple must advance the signed authorization nonce"
        );
    }
}
