// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";

/// examples/05-session-key-account, executed against the real opcodes.
///
/// The account runs no `ecrecover`: it asks SIGPARAM which key signed and applies
/// a two-tier policy. The owner may do anything; a session key may only drive
/// allowlisted `(target, selector)` pairs with zero value, which the VERIFY frame
/// enforces by walking every SENDER frame of the transaction before approving,
/// and only through transactions whose expiry frame's deadline is within the
/// key's `validUntil`.
contract SessionKeyAccountTest is FrameTest {
    address constant OWNER = address(0x0BEEF);
    address constant SESSION = address(0x5E55);
    address constant STRANGER = address(0xBAD);
    address constant TOKEN = address(0x7043);
    address constant OTHER_TOKEN = address(0x7044);

    /// EIP-8141 EXPIRY_VERIFIER predeploy: target of the expiry frame.
    address constant EXPIRY_VERIFIER = address(0x8141);
    uint64 constant VALID_UNTIL = 2_000_000_000;

    bytes4 constant TRANSFER = bytes4(keccak256("transfer(address,uint256)"));
    bytes4 constant APPROVE_SEL = bytes4(keccak256("approve(address,uint256)"));

    address account;

    function setUp() public {
        account = deployAccountWithArgs("SessionKeyAccount", abi.encode(OWNER));

        // Configured through the account's own admin path, so the mapping slots are
        // whatever the contract says they are. A silently wrong slot here would make
        // every refusal below pass for the wrong reason.
        vm.startPrank(OWNER);
        (bool ok,) = account.call(abi.encodeWithSignature("setSessionKey(address,uint64)", SESSION, VALID_UNTIL));
        require(ok, "setSessionKey failed");
        (ok,) = account.call(abi.encodeWithSignature("setAllowedCall(address,bytes4,bool)", TOKEN, TRANSFER, true));
        require(ok, "setAllowedCall failed");
        vm.stopPrank();

        assertEq(_sessionKeys(SESSION), VALID_UNTIL, "session key not registered");
        assertTrue(_allowedCall(TOKEN, TRANSFER), "allowlist entry not registered");
        assertFalse(_allowedCall(TOKEN, APPROVE_SEL), "approve() must not be allowlisted");
    }

    function _sessionKeys(address key) internal view returns (uint64) {
        (bool ok, bytes memory ret) = account.staticcall(abi.encodeWithSignature("sessionKeys(address)", key));
        require(ok, "sessionKeys() failed");
        return abi.decode(ret, (uint64));
    }

    function _allowedCall(address target, bytes4 selector) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            account.staticcall(abi.encodeWithSignature("allowedCall(address,bytes4)", target, selector));
        require(ok, "allowedCall() failed");
        return abi.decode(ret, (bool));
    }

    /// The expiry verifier frame: VERIFY mode, flags 0, target EXPIRY_VERIFIER,
    /// data exactly the 8-byte big-endian deadline. The protocol admits it only
    /// as frame 0, and the account relies on that.
    function _expiryFrame(uint64 deadline) internal pure returns (IFrameVm.FrameTxFrame memory) {
        return IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: 0,
            target: EXPIRY_VERIFIER,
            gasLimit: 100_000,
            stateGasLimit: 0,
            value: 0,
            data: abi.encodePacked(deadline),
            status: 1,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
    }

    /// Self-relay layout with a deadline: frame 0 is the expiry frame, frame 1 the
    /// account's VERIFY frame, frame 2 the single SENDER frame the session-key
    /// policy is applied to. The deadline sits exactly on the key's `validUntil`,
    /// pinning the boundary as allowed.
    function _ctx(address signer, address target, uint256 value, bytes memory data)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        ctx = _ctx(signer, target, value, data, SCOPE_BOTH);
    }

    function _ctx(address signer, address target, uint256 value, bytes memory data, uint64 scopes)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        ctx = _ctxNoExpiry(signer, target, value, data, scopes);
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](3);
        frames[0] = _expiryFrame(VALID_UNTIL);
        frames[1] = ctx.frames[0];
        frames[2] = ctx.frames[1];
        ctx.frames = frames;
        ctx.frameIndex = 1;
    }

    /// The pre-expiry layout: no deadline anywhere in the transaction.
    function _ctxNoExpiry(address signer, address target, uint256 value, bytes memory data, uint64 scopes)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](2);
        frames[0] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(scopes),
            target: account,
            gasLimit: 200_000,
            stateGasLimit: 0,
            value: 0,
            data: abi.encodeWithSignature("validate()"),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        frames[1] = IFrameVm.FrameTxFrame({
            mode: MODE_SENDER,
            flags: 0,
            target: target,
            gasLimit: 200_000,
            stateGasLimit: 0,
            value: value,
            data: data,
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        IFrameVm.FrameTxSignature[] memory sigs = new IFrameVm.FrameTxSignature[](1);
        sigs[0] = secpSig(signer);
        uint256[] memory nonceKeys = legacyNonceKeys();
        ctx = IFrameVm.FrameTx({
            sender: account,
            nonce: 0,
            legacyNonce: 0,
            nonceKeys: nonceKeys,
            nonceKeysHash: LEGACY_NONCE_KEYS_HASH,
            stateGasLeft: 0,
            sigHash: bytes32(uint256(0xf00d)),
            maxCost: 0,
            maxPriorityFeePerGas: 0,
            maxFeePerGas: 0,
            maxFeePerBlobGas: 0,
            blobCount: 0,
            frameIndex: 0,
            frames: frames,
            signatures: sigs,
            recentRootReferences: new IFrameVm.FrameTxRecentRootReference[](0),
            trace: emptyTrace(),
            approvableScopes: scopes
        });
    }

    function _transfer() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(TRANSFER, address(0x1234), uint256(1));
    }

    // ------------------------------------------------------------------ positive

    function test_sessionKeyOnAllowlistedCallApproves() public {
        assertApprovesFrame(
            account,
            _ctx(SESSION, TOKEN, 0, _transfer()),
            "session key on an allowlisted (target, selector) must approve"
        );
    }

    /// The owner is unconditional: the same frame the session key is refused for
    /// below is fine when the owner signed it.
    function test_ownerBypassesTheAllowlist() public {
        assertApprovesFrame(
            account,
            _ctx(OWNER, OTHER_TOKEN, 1 ether, abi.encodeWithSelector(APPROVE_SEL, OWNER, uint256(1))),
            "owner must approve regardless of the frame policy"
        );
    }

    /// The account approves `frame.flags & 0x3` rather than a hardcoded 0x3, so the
    /// same code serves the sponsored layout where a paymaster approves payment.
    function test_executionOnlyFrameApproves() public {
        assertApprovesFrame(
            account, _ctx(SESSION, TOKEN, 0, _transfer(), SCOPE_EXECUTION), "flags 0x2 must approve 0x2"
        );
    }

    /// The owner wins wherever it appears, so a stray session-key entry cannot
    /// downgrade an owner-signed transaction into the restricted policy.
    function test_ownerWinsOverSessionKeyEntry() public {
        IFrameVm.FrameTx memory ctx =
            _ctx(SESSION, OTHER_TOKEN, 0, abi.encodeWithSelector(APPROVE_SEL, OWNER, uint256(1)));
        IFrameVm.FrameTxSignature[] memory sigs = new IFrameVm.FrameTxSignature[](2);
        sigs[0] = secpSig(SESSION);
        sigs[1] = secpSig(OWNER);
        ctx.signatures = sigs;
        assertApprovesFrame(account, ctx, "an owner entry anywhere in the list wins");
    }

    // ------------------------------------------------------------------ negative

    function test_unknownSignerRefused() public {
        assertRefusesFrame(account, _ctx(STRANGER, TOKEN, 0, _transfer()), "an untrusted key must not approve");
    }

    function test_sessionKeyOnNonAllowlistedTargetRefused() public {
        assertRefusesFrame(
            account, _ctx(SESSION, OTHER_TOKEN, 0, _transfer()), "a target outside the allowlist must be refused"
        );
    }

    function test_sessionKeyOnNonAllowlistedSelectorRefused() public {
        assertRefusesFrame(
            account,
            _ctx(SESSION, TOKEN, 0, abi.encodeWithSelector(APPROVE_SEL, OWNER, uint256(1))),
            "a selector outside the allowlist must be refused"
        );
    }

    /// Session keys never move ETH, even to an allowlisted target.
    function test_sessionKeyWithValueRefused() public {
        assertRefusesFrame(account, _ctx(SESSION, TOKEN, 1 wei, _transfer()), "a session key must not send value");
    }

    /// FRAMEDATALOAD zero-pads past the end of `data`, so a short frame would read as
    /// selector 0x00000000 without the explicit length check.
    function test_sessionKeyWithShortFrameDataRefused() public {
        assertRefusesFrame(account, _ctx(SESSION, TOKEN, 0, hex"a905"), "frame data shorter than a selector");
    }

    /// The policy applies to EVERY sender frame, not just the first: approving
    /// execution once authorises all of them.
    function test_secondSenderFrameOffAllowlistRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(SESSION, TOKEN, 0, _transfer());
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](4);
        frames[0] = ctx.frames[0];
        frames[1] = ctx.frames[1];
        frames[2] = ctx.frames[2];
        frames[3] = IFrameVm.FrameTxFrame({
            mode: MODE_SENDER,
            flags: 0,
            target: OTHER_TOKEN,
            gasLimit: 200_000,
            stateGasLimit: 0,
            value: 0,
            data: _transfer(),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        ctx.frames = frames;
        assertRefusesFrame(account, ctx, "a later sender frame must be checked too");
    }

    // -------------------------------------------------------------------- expiry

    /// A session-key transaction with no expiry frame could be replayed forever;
    /// the account refuses it outright.
    function test_sessionKeyWithoutExpiryFrameRefused() public {
        assertRefusesFrame(
            account,
            _ctxNoExpiry(SESSION, TOKEN, 0, _transfer(), SCOPE_BOTH),
            "a session key without an expiry frame must be refused"
        );
    }

    /// A deadline one second past `validUntil` would let the key act after it
    /// expired. The positive cases above pin `deadline == validUntil` as allowed.
    function test_expiryBeyondSessionKeyRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(SESSION, TOKEN, 0, _transfer());
        ctx.frames[0] = _expiryFrame(VALID_UNTIL + 1);
        assertRefusesFrame(account, ctx, "a deadline outliving the key must be refused");
    }

    /// The owner's authority is not time-bounded, so no expiry frame is required.
    function test_ownerNeedsNoExpiryFrame() public {
        assertApprovesFrame(
            account,
            _ctxNoExpiry(OWNER, TOKEN, 0, _transfer(), SCOPE_BOTH),
            "the owner must approve without an expiry frame"
        );
    }

    /// An explicit 32-byte digest commits to nothing about the frame list, so it can
    /// never be authority to grant execution.
    function test_explicitDigestNotTrusted() public {
        IFrameVm.FrameTx memory ctx = _ctx(SESSION, TOKEN, 0, _transfer());
        ctx.signatures[0].msgHash = bytes32(uint256(0xbeef));
        assertRefusesFrame(account, ctx, "explicit-digest entry must not authorise");
    }

    /// Same signer and frames as the positive case; only the permitted scope changes.
    function test_scopeNoneRefused() public {
        assertRefusesFrame(account, _ctx(SESSION, TOKEN, 0, _transfer(), SCOPE_NONE), "APPROVE_NONE must revert");
    }
}
