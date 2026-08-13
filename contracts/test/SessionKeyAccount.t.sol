// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";

/// examples/05-session-key-account, executed against the real opcodes.
///
/// The account runs no `ecrecover`: it asks SIGPARAM which key signed and applies
/// a two-tier policy. The owner may do anything; a session key may only drive
/// allowlisted `(target, selector)` pairs with zero value, which the VERIFY frame
/// enforces by walking every SENDER frame of the transaction before approving.
contract SessionKeyAccountTest is FrameTest {
    address constant OWNER = address(0x0BEEF);
    address constant SESSION = address(0x5E55);
    address constant STRANGER = address(0xBAD);
    address constant TOKEN = address(0x7043);
    address constant OTHER_TOKEN = address(0x7044);

    bytes4 constant TRANSFER = bytes4(keccak256("transfer(address,uint256)"));
    bytes4 constant APPROVE_SEL = bytes4(keccak256("approve(address,uint256)"));

    address account;

    function setUp() public {
        account = deployAccountWithArgs("SessionKeyAccount", abi.encode(OWNER));

        // Configured through the account's own admin path, so the mapping slots are
        // whatever the contract says they are. A silently wrong slot here would make
        // every refusal below pass for the wrong reason.
        vm.startPrank(OWNER);
        (bool ok,) = account.call(abi.encodeWithSignature("setSessionKey(address,bool)", SESSION, true));
        require(ok, "setSessionKey failed");
        (ok,) = account.call(abi.encodeWithSignature("setAllowedCall(address,bytes4,bool)", TOKEN, TRANSFER, true));
        require(ok, "setAllowedCall failed");
        vm.stopPrank();

        assertTrue(_sessionKeys(SESSION), "session key not registered");
        assertTrue(_allowedCall(TOKEN, TRANSFER), "allowlist entry not registered");
        assertFalse(_allowedCall(TOKEN, APPROVE_SEL), "approve() must not be allowlisted");
    }

    function _sessionKeys(address key) internal view returns (bool) {
        (bool ok, bytes memory ret) = account.staticcall(abi.encodeWithSignature("sessionKeys(address)", key));
        require(ok, "sessionKeys() failed");
        return abi.decode(ret, (bool));
    }

    function _allowedCall(address target, bytes4 selector) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            account.staticcall(abi.encodeWithSignature("allowedCall(address,bytes4)", target, selector));
        require(ok, "allowedCall() failed");
        return abi.decode(ret, (bool));
    }

    /// Self-relay layout: frame 0 is the account's VERIFY frame, frame 1 the single
    /// SENDER frame the session-key policy is applied to.
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
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](2);
        frames[0] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(scopes),
            target: account,
            gasLimit: 200_000,
            value: 0,
            data: abi.encodeWithSignature("validate()"),
            status: 0
        });
        frames[1] = IFrameVm.FrameTxFrame({
            mode: MODE_SENDER, flags: 0, target: target, gasLimit: 200_000, value: value, data: data, status: 0
        });
        IFrameVm.FrameTxSignature[] memory sigs = new IFrameVm.FrameTxSignature[](1);
        sigs[0] = secpSig(signer);
        ctx = IFrameVm.FrameTx({
            sender: account,
            nonce: 0,
            sigHash: bytes32(uint256(0xf00d)),
            maxCost: 0,
            frameIndex: 0,
            approvableScopes: scopes,
            frames: frames,
            signatures: sigs
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
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](3);
        frames[0] = ctx.frames[0];
        frames[1] = ctx.frames[1];
        frames[2] = IFrameVm.FrameTxFrame({
            mode: MODE_SENDER, flags: 0, target: OTHER_TOKEN, gasLimit: 200_000, value: 0, data: _transfer(), status: 0
        });
        ctx.frames = frames;
        assertRefusesFrame(account, ctx, "a later sender frame must be checked too");
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
