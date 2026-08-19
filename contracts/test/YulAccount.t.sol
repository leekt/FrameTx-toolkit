// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccountTestSuite} from "./AccountTestSuite.sol";
import {IFrameVm} from "./FrameTest.sol";

/// Shared assertions for the portable-verbatim and patched-builtin spellings
/// of the minimal Yul account. Both runtimes implement the same one-index
/// `validate(uint256[])` ABI and keep the owner in slot zero.
abstract contract YulAccountTestBase is AccountTestSuite {
    address constant ACCOUNT = address(0xACC2);
    address constant OWNER = address(0x0BEEF);
    address constant STRANGER = address(0xBAD);

    function accountUnderTest() internal pure override returns (address) {
        return ACCOUNT;
    }

    function accountAuthorizationSignatures()
        internal
        pure
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = secpSig(OWNER);
    }

    function _install(bytes memory runtime) internal {
        vm.etch(ACCOUNT, runtime);
        vm.store(ACCOUNT, bytes32(0), bytes32(uint256(uint160(OWNER))));
    }

    function _ctx(address signer) internal pure returns (IFrameVm.FrameTx memory ctx) {
        return _ctx(signer, bytes32(0));
    }

    function _ctx(address signer, bytes32 msgHash)
        internal
        pure
        returns (IFrameVm.FrameTx memory ctx)
    {
        ctx = verifyContext(ACCOUNT, SCOPE_BOTH, bytes32(0));
        ctx.frames[0].data = validationCalldata(selected(0));
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = secpSig(signer);
        ctx.signatures[0].msgHash = msgHash;
    }

    function test_ownerApproves() public {
        assertApprovesFrame(ACCOUNT, _ctx(OWNER), "owner should approve");
    }

    /// A validly signed transaction from a key the account does not trust: the
    /// protocol accepts the signature, the account rejects the selected signer.
    function test_strangerRefused() public {
        assertRefusesFrame(ACCOUNT, _ctx(STRANGER), "stranger must not approve");
    }

    /// The owner entry is otherwise valid and the canonical-hash control above
    /// approves; changing only msg to an explicit digest must remove authority.
    function test_explicitDigestFromOwnerRefused() public {
        assertRefusesFrame(
            ACCOUNT,
            _ctx(OWNER, keccak256("not the transaction hash")),
            "an explicit-digest signature must not approve the frame list"
        );
    }

    /// The runtime derives PAYMENT from this frame, but the host permits no
    /// approval. Refusal proves the call does not succeed through plain STOP.
    function test_scopeNoneHostMaskRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.frames[0].flags = uint8(SCOPE_PAYMENT);
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(ACCOUNT, ctx, "host must reject PAYMENT when no scope is permitted");
    }

    function test_wrongValidationSelectorRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.frames[0].data =
            abi.encodePacked(bytes4(0xDEADBEEF), uint256(0x20), uint256(1), uint256(0));
        assertRefusesFrame(ACCOUNT, ctx, "validation selector must match the shared account ABI");
    }

    function test_nonCanonicalSignatureArrayOffsetRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.frames[0].data =
            abi.encodePacked(bytes4(0x25B90494), uint256(0x40), uint256(1), uint256(0));
        assertRefusesFrame(ACCOUNT, ctx, "signature-index array offset must be canonical");
    }

    function test_multipleSelectedSignatureIndicesRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.frames[0].data = validationCalldata(selected(0, 0));
        assertRefusesFrame(ACCOUNT, ctx, "minimal Yul account accepts exactly one index");
    }

    function test_trailingValidationCalldataRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.frames[0].data = bytes.concat(validationCalldata(selected(0)), hex"00");
        assertRefusesFrame(ACCOUNT, ctx, "minimal decoder rejects trailing calldata");
    }
}

/// contracts/src/accounts/account.yul, compiled with stock-solc-compatible
/// `verbatim_*` opcodes. This is the runtime object after its 11-byte constructor.
contract YulAccountTest is YulAccountTestBase {
    bytes constant RUNTIME =
        hex"36600557005b606436146010575f5ffd5b6325b904945f3560e01c146022575f5ffd5b602060043514602f575f5ffd5b600160243514603c575f5ffd5b6044355f81b4600282b415600ab0600681b3806056575f5ffd5b82845f54141615606557805f5faa5b5f5ffd";

    function setUp() public {
        _install(RUNTIME);
    }
}

// contracts/src/accounts/account-builtins.yul, compiled by the patched solc
// with `--experimental --evm-version @future`.
contract YulBuiltinAccountTest is YulAccountTestBase {
    bytes constant RUNTIME =
        hex"3615606557606436036061576325b904945f3560e01c03605d5760206004350360595760016024350360555760443560025f82b491b4156006600ab0b39182156051575f541416604d575f80fd5b5f80aa5b5f80fd5b5f80fd5b5f80fd5b5f80fd5b5f80fd5b00";

    function setUp() public {
        _install(RUNTIME);
    }
}
