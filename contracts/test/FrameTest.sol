// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// The EIP-8141 cheatcodes, declared here rather than imported.
///
/// They live in the patched Foundry (`leekt/foundry`) but are not yet in a
/// published `forge-std`, so tests declare the interface against `vm`'s address.
/// Remove this once the cheatcode assets are regenerated and released.
interface IFrameVm {
    struct FrameTxFrame {
        /// 0 DEFAULT, 1 VERIFY, 2 SENDER.
        uint8 mode;
        /// Low two bits are the approval scope.
        uint8 flags;
        /// Already resolved: a null target resolves to the sender.
        address target;
        uint64 gasLimit;
        uint256 value;
        bytes data;
        /// 0 failed, 1 success, 2 skipped. Only read for frames before the current one.
        uint8 status;
    }

    struct FrameTxSignature {
        /// 0 ARBITRARY, 1 SECP256K1, 2 P256.
        uint8 scheme;
        /// Already resolved. Ignored for ARBITRARY, which has no protocol signer.
        address signer;
        bytes32 msgHash;
        bytes signature;
    }

    struct FrameTx {
        address sender;
        uint64 nonce;
        bytes32 sigHash;
        uint256 maxCost;
        uint64 frameIndex;
        /// Scopes APPROVE may grant, mirroring `frame.flags & 0x3`.
        uint64 approvableScopes;
        FrameTxFrame[] frames;
        FrameTxSignature[] signatures;
    }

    function setFrameTx(FrameTx calldata frameTx) external;
    function clearFrameTx() external;
}

// Base class for testing EIP-8141 accounts under Foundry.
//
// Accounts that use the frame opcodes cannot be compiled by Foundry: its
// evm_version enum does not accept the experimental future version. They are
// built by script/build-frame-accounts.sh with the patched solc and installed
// here with vm.etch. Execution itself is real -- the patched revm implements the
// opcodes, and the frame context comes from the setFrameTx cheatcode.
abstract contract FrameTest is Test {
    IFrameVm internal constant fvm = IFrameVm(address(vm));

    /// APPROVE scopes.
    uint64 internal constant SCOPE_NONE = 0;
    uint64 internal constant SCOPE_PAYMENT = 1;
    uint64 internal constant SCOPE_EXECUTION = 2;
    uint64 internal constant SCOPE_BOTH = 3;

    /// Frame modes.
    uint8 internal constant MODE_DEFAULT = 0;
    uint8 internal constant MODE_VERIFY = 1;
    uint8 internal constant MODE_SENDER = 2;

    /// Installs an account's compiled runtime, built by build-frame-accounts.sh.
    /// Fails loudly rather than silently etching nothing if the artifact is absent.
    function deployAccount(string memory name, address at) internal returns (address) {
        string memory path =
            string.concat(vm.projectRoot(), "/out-frame/", name, "/", name, ".bin-runtime");
        string memory hexCode = vm.readFile(path);
        bytes memory runtime = vm.parseBytes(string.concat("0x", hexCode));
        require(runtime.length > 0, string.concat("empty artifact for ", name));
        vm.etch(at, runtime);
        return at;
    }

    /// A single-frame VERIFY context: the common shape for validating an account.
    function verifyContext(address account, uint64 approvableScopes, bytes32 sigHash)
        internal
        pure
        returns (IFrameVm.FrameTx memory)
    {
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](1);
        frames[0] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(approvableScopes),
            target: account,
            gasLimit: 100_000,
            value: 0,
            data: "",
            status: 0
        });
        return IFrameVm.FrameTx({
            sender: account,
            nonce: 0,
            sigHash: sigHash,
            maxCost: 0,
            frameIndex: 0,
            approvableScopes: approvableScopes,
            frames: frames,
            signatures: new IFrameVm.FrameTxSignature[](0)
        });
    }

    /// One protocol-verified secp256k1 signature entry.
    function secpSig(address signer) internal pure returns (IFrameVm.FrameTxSignature memory) {
        return
            IFrameVm.FrameTxSignature({
                scheme: 1, signer: signer, msgHash: bytes32(0), signature: ""
            });
    }

    /// Calls the account as the ENTRY_POINT would for its VERIFY frame.
    function callAccount(address account) internal returns (bool ok) {
        (ok,) = account.call("");
    }

    /// Asserts the account approves under this context.
    function assertApproves(address account, IFrameVm.FrameTx memory ctx, string memory reason)
        internal
    {
        fvm.setFrameTx(ctx);
        assertTrue(callAccount(account), reason);
        fvm.clearFrameTx();
    }

    /// Asserts the account refuses under this context.
    ///
    /// A refusal and a wrongly-scoped APPROVE both surface as a failed call, so
    /// pair this with a positive case that pins the scope.
    function assertRefuses(address account, IFrameVm.FrameTx memory ctx, string memory reason)
        internal
    {
        fvm.setFrameTx(ctx);
        assertFalse(callAccount(account), reason);
        fvm.clearFrameTx();
    }
}
