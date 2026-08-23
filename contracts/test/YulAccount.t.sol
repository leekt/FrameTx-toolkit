// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccountTestSuite} from "./AccountTestSuite.sol";
import {IFrameVm} from "./FrameTest.sol";

/// Shared assertions for the portable-verbatim and patched-builtin spellings
/// of the minimal Yul account. Both runtimes implement the same one-index
/// `validate(uint256)` ABI and keep the owner in slot zero.
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
        ctx.frames[0].data = validationCalldata(0);
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

    /// The policy intentionally trusts the protocol-resolved signer rather than
    /// restricting the native scheme to secp256k1.
    function test_p256OwnerApproves() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.signatures[0] = p256Sig(OWNER);
        assertApprovesFrame(ACCOUNT, ctx, "the same resolved owner may use native P256");
    }

    function test_mldsaOwnerApproves() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.signatures[0] = mldsaSig(OWNER);
        assertApprovesFrame(ACCOUNT, ctx, "the same resolved owner may use native ML-DSA-44");
    }

    /// ARBITRARY entries have no resolved signer. Asking SIGPARAM for one must
    /// exceptional-halt rather than treating its zero fixture signer as authority.
    function test_arbitraryEntryRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.signatures[0] = arbitrarySig(hex"01");
        assertRefusesFrame(ACCOUNT, ctx, "an ARBITRARY witness has no resolved signer");
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
        ctx.frames[0].data = abi.encodePacked(bytes4(0xDEADBEEF), uint256(0));
        assertRefusesFrame(ACCOUNT, ctx, "validation selector must match validate(uint256)");
    }

    function test_legacyDynamicArrayEncodingRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.frames[0].data = abi.encodeWithSelector(bytes4(0x25B90494), selected(0));
        assertRefusesFrame(ACCOUNT, ctx, "the former validate(uint256[]) ABI must be rejected");
    }

    function test_shortValidationCalldataRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.frames[0].data = abi.encodePacked(bytes4(0xCE4D01A3), bytes31(0));
        assertRefusesFrame(ACCOUNT, ctx, "validate(uint256) requires all 36 calldata bytes");
    }

    function test_trailingValidationCalldataRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.frames[0].data = bytes.concat(validationCalldata(0), hex"00");
        assertRefusesFrame(ACCOUNT, ctx, "minimal decoder rejects trailing calldata");
    }
}

/// contracts/src/accounts/account.yul, compiled with stock-solc-compatible
/// `verbatim_*` opcodes. This is the runtime object after its 11-byte constructor.
contract YulAccountTest is YulAccountTestBase {
    bytes constant RUNTIME =
        hex"36600557005b602436146010575f5ffd5b63ce4d01a35f3560e01c146022575f5ffd5b6004355f81b4600282b415600ab0600681b380603c575f5ffd5b82845f54141615604b57805f5faa5b5f5ffd";

    function setUp() public {
        _install(RUNTIME);
    }
}

// contracts/src/accounts/account-builtins.yul, compiled by the patched solc
// with `--experimental --evm-version @future`.
contract YulBuiltinAccountTest is YulAccountTestBase {
    bytes constant RUNTIME =
        hex"3615604b576024360360475763ce4d01a35f3560e01c0360435760043560025f82b491b4156006600ab0b3918215603f575f541416603b575f80fd5b5f80aa5b5f80fd5b5f80fd5b5f80fd5b00";

    function setUp() public {
        _install(RUNTIME);
    }
}
