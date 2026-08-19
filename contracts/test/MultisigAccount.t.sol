// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccountTestSuite} from "./AccountTestSuite.sol";
import {IFrameVm} from "./FrameTest.sol";

/// contracts/src/accounts/MultisigAccount.sol, executed against the real opcodes.
///
/// The account runs no `ecrecover`. Every protocol signature was already checked
/// against its selected message, which may be the canonical transaction hash or
/// an explicit digest. These tests assert the account counts only distinct owner
/// entries with `msgHash == 0`, meaning they signed THIS transaction, and approves
/// once `threshold` is reached.
contract MultisigAccountTest is AccountTestSuite {
    /// Deliberately ascending: the account dedups by requiring counted owners to
    /// appear in strictly ascending address order, so a fixture in any other order
    /// would test the sort rule instead of the threshold rule.
    address constant OWNER_A = address(0x1111);
    address constant OWNER_B = address(0x2222);
    address constant OWNER_C = address(0x3333);
    address constant STRANGER_X = address(0x9991);
    address constant STRANGER_Y = address(0x9992);

    address account;

    function setUp() public {
        address[] memory owners = new address[](3);
        owners[0] = OWNER_A;
        owners[1] = OWNER_B;
        owners[2] = OWNER_C;
        account = deployAccountWithArgs("MultisigAccount", abi.encode(owners, uint256(2)));

        // The constructor is the whole setup; if it did not take, every refusal
        // below would pass for the wrong reason.
        assertEq(_threshold(), 2, "threshold not stored");
        assertTrue(_isOwner(OWNER_B), "owner set not stored");
        assertFalse(_isOwner(STRANGER_X), "stranger must not be an owner");
    }

    function accountUnderTest() internal view override returns (address) {
        return account;
    }

    function accountAuthorizationSignatures()
        internal
        pure
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](2);
        signatures[0] = secpSig(OWNER_A);
        signatures[1] = secpSig(OWNER_B);
    }

    function _threshold() internal view returns (uint256) {
        (bool ok, bytes memory ret) = account.staticcall(abi.encodeWithSignature("threshold()"));
        require(ok, "threshold() failed");
        return abi.decode(ret, (uint256));
    }

    function _isOwner(address who) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            account.staticcall(abi.encodeWithSignature("isOwner(address)", who));
        require(ok, "isOwner() failed");
        return abi.decode(ret, (bool));
    }

    /// A self-relay VERIFY frame carrying `validate(uint256[])`, with the given signature list.
    function _ctx(
        uint64 scopes,
        IFrameVm.FrameTxSignature[] memory sigs,
        uint256[] memory signatureIndices
    ) internal view returns (IFrameVm.FrameTx memory ctx) {
        ctx = verifyContext(account, scopes, bytes32(uint256(0xf00d)));
        ctx.frames[0].data = validationCalldata(signatureIndices);
        ctx.signatures = sigs;
    }

    function _sigs(address a, address b)
        internal
        pure
        returns (IFrameVm.FrameTxSignature[] memory sigs)
    {
        sigs = new IFrameVm.FrameTxSignature[](2);
        sigs[0] = secpSig(a);
        sigs[1] = secpSig(b);
    }

    // ------------------------------------------------------------------ positive

    function test_thresholdOfOwnersApproves() public {
        assertApprovesFrame(
            account,
            _ctx(SCOPE_BOTH, _sigs(OWNER_A, OWNER_B), selected(0, 1)),
            "2-of-3 must approve"
        );
    }

    /// The third owner is not required, and a set above the threshold still approves.
    function test_allThreeOwnersApprove() public {
        IFrameVm.FrameTxSignature[] memory sigs = new IFrameVm.FrameTxSignature[](3);
        sigs[0] = secpSig(OWNER_A);
        sigs[1] = secpSig(OWNER_B);
        sigs[2] = secpSig(OWNER_C);
        assertApprovesFrame(
            account, _ctx(SCOPE_BOTH, sigs, selected(0, 1, 2)), "3-of-3 must approve"
        );
    }

    /// The account approves `frame.flags & 0x3` rather than a hardcoded 0x3, so the
    /// same code serves the sponsored layout where a paymaster approves payment.
    function test_executionOnlyFrameApproves() public {
        assertApprovesFrame(
            account,
            _ctx(SCOPE_EXECUTION, _sigs(OWNER_A, OWNER_B), selected(0, 1)),
            "flags 0x2 must approve 0x2"
        );
    }

    /// Foreign entries -- a paymaster's own signature, say -- must be skipped rather
    /// than halt the frame. SIGPARAM(0x00) on an ARBITRARY entry is an exceptional
    /// halt, so the account reads the scheme first; this proves it does.
    function test_arbitraryEntryIsSkippedNotFatal() public {
        IFrameVm.FrameTxSignature[] memory sigs = new IFrameVm.FrameTxSignature[](3);
        sigs[0] = IFrameVm.FrameTxSignature({
            scheme: 0, signer: address(0xDEAD), msgHash: bytes32(0), signature: hex"c0ffee"
        });
        sigs[1] = secpSig(OWNER_A);
        sigs[2] = secpSig(OWNER_B);
        assertApprovesFrame(
            account,
            _ctx(SCOPE_BOTH, sigs, selected(0, 1, 2)),
            "ARBITRARY entry must not break 2-of-3"
        );
    }

    // ------------------------------------------------------------------ negative

    function test_singleOwnerBelowThresholdRefused() public {
        IFrameVm.FrameTxSignature[] memory sigs = new IFrameVm.FrameTxSignature[](1);
        sigs[0] = secpSig(OWNER_A);
        assertRefusesFrame(
            account, _ctx(SCOPE_BOTH, sigs, selected(0)), "1-of-3 is below the threshold"
        );
    }

    function test_nonOwnersRefused() public {
        assertRefusesFrame(
            account,
            _ctx(SCOPE_BOTH, _sigs(STRANGER_X, STRANGER_Y), selected(0, 1)),
            "non-owners must not approve"
        );
    }

    /// One owner cannot reach the threshold by signing twice: counted owners must
    /// strictly ascend, and a repeat is not greater than itself.
    function test_duplicateOwnerRefused() public {
        assertRefusesFrame(
            account,
            _ctx(SCOPE_BOTH, _sigs(OWNER_A, OWNER_A), selected(0, 1)),
            "a repeated owner must not count twice"
        );
    }

    /// Same two owners as the positive case, descending. The dedup rule is a hard
    /// require, so a mis-ordered envelope invalidates rather than silently counting one.
    function test_descendingOwnerOrderRefused() public {
        assertRefusesFrame(
            account,
            _ctx(SCOPE_BOTH, _sigs(OWNER_B, OWNER_A), selected(0, 1)),
            "owner sigs must be sorted ascending"
        );
    }

    /// A non-zero `msg` is a digest the owner signed in some other context. Counting
    /// it would let anyone staple an unrelated owner signature onto this transaction.
    function test_explicitDigestNotCounted() public {
        IFrameVm.FrameTxSignature[] memory sigs = _sigs(OWNER_A, OWNER_B);
        sigs[1].msgHash = bytes32(uint256(0xbeef));
        assertRefusesFrame(
            account, _ctx(SCOPE_BOTH, sigs, selected(0, 1)), "explicit-digest entry must not count"
        );
    }

    /// P256 entries are protocol-verified too, but this account restricts itself to
    /// SECP256K1, so a P256 owner entry does not count toward the threshold.
    function test_p256EntryNotCounted() public {
        IFrameVm.FrameTxSignature[] memory sigs = _sigs(OWNER_A, OWNER_B);
        sigs[1].scheme = 2;
        assertRefusesFrame(
            account, _ctx(SCOPE_BOTH, sigs, selected(0, 1)), "P256 entry must not count here"
        );
    }

    /// Same signers that approve above; only the frame's permitted scope changes.
    /// APPROVE_NONE always reverts, so a frame granting nothing invalidates the tx.
    function test_scopeNoneRefused() public {
        assertRefusesFrame(
            account,
            _ctx(SCOPE_NONE, _sigs(OWNER_A, OWNER_B), selected(0, 1)),
            "APPROVE_NONE must revert"
        );
    }
}
