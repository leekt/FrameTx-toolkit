// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// Frame-context cheatcodes, declared here rather than imported.
///
/// They live in the patched Foundry (`leekt/foundry`) but are not yet in a
/// published `forge-std`, so tests declare the interface against `vm`'s address.
/// `setFrameTx` copies every value supplied by the test; it does not derive or
/// validate the non-normative nonce-key, recent-root, POST_TX, or trace fields.
interface IFrameVm {
    struct FrameTxFrame {
        /// Normative: 0 DEFAULT, 1 VERIFY, 2 SENDER. Fixture-only: 3 POST_TX.
        uint8 mode;
        /// Low two bits are the approval scope.
        uint8 flags;
        /// Host-supplied resolved target; a real null target resolves to sender.
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
        /// Host-supplied resolved signer. Ignored for ARBITRARY.
        address signer;
        bytes32 msgHash;
        bytes signature;
    }

    /// Host-supplied non-normative tooling-fixture data; not verified here.
    struct FrameTxRecentRootReference {
        bytes32 sourceId;
        uint64 slot;
        bytes32 root;
    }

    struct FrameTxBalanceDiff {
        address account;
        uint256 balanceBefore;
        uint256 balanceAfter;
    }

    struct FrameTxStorageDiff {
        address account;
        uint256 key;
        uint256 valueBefore;
        uint256 valueAfter;
    }

    struct FrameTxDeployedContract {
        address account;
        bytes32 codeHash;
    }

    struct FrameTxAccountDiff {
        address account;
        bool nonceChanged;
        bytes32 codeHashBefore;
        bytes32 codeHashAfter;
    }

    struct FrameTxEvent {
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    /// Host-supplied non-normative POST_TX tooling-fixture trace.
    struct FrameTxTrace {
        FrameTxBalanceDiff[] balanceDiffs;
        FrameTxStorageDiff[] storageDiffs;
        FrameTxDeployedContract[] deployedContracts;
        FrameTxAccountDiff[] accountDiffs;
        FrameTxEvent[] events;
        uint256 gasPreCharge;
        address gasPayer;
    }

    struct FrameTx {
        address sender;
        /// TXPARAM 0x01: baseline scalar wire nonce, or a fixture-supplied shared sequence.
        uint64 nonce;
        /// Host-supplied non-normative fixture selector TXPARAM 0x0C.
        uint64 legacyNonce;
        /// Host-supplied non-normative fixture selector data for 0x0D/0x10.
        uint256[] nonceKeys;
        /// Host-supplied non-normative fixture value for TXPARAM 0x0E; not derived here.
        bytes32 nonceKeysHash;
        /// Canonical EIP-8141 signature hash; supplied rather than derived by the cheatcode.
        bytes32 sigHash;
        uint256 maxCost;
        uint256 maxPriorityFeePerGas;
        uint256 maxFeePerGas;
        uint256 maxFeePerBlobGas;
        uint64 blobCount;
        uint64 frameIndex;
        FrameTxFrame[] frames;
        FrameTxSignature[] signatures;
        /// Host-supplied non-normative fixture data for TXPARAM 0x0F/B6.
        FrameTxRecentRootReference[] recentRootReferences;
        /// Host-supplied non-normative fixture data for B7-B9.
        FrameTxTrace trace;
        /// Scopes APPROVE may grant, mirroring `frame.flags & 0x3`.
        uint64 approvableScopes;
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

    /// Normative frame modes plus the non-normative fixture MODE_POST_TX.
    uint8 internal constant MODE_DEFAULT = 0;
    uint8 internal constant MODE_VERIFY = 1;
    uint8 internal constant MODE_SENDER = 2;
    uint8 internal constant MODE_POST_TX = 3;

    /// Synthetic host-context hash for the fixture nonce-key list `[0]`.
    bytes32 internal constant LEGACY_NONCE_KEYS_HASH =
        0xada5013122d395ba3c54772283fb069b10426056ef8ca54750cb9bb552a59e7d;

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

    /// Deploys an account by running its real constructor, from the `.bin` artifact.
    ///
    /// `deployAccount` etches runtime code, which leaves storage empty and every
    /// `immutable` as the zero placeholder solc emits into `--bin-runtime`. An
    /// account configured through immutables (SponsoringPaymaster) can only be set up
    /// this way; for one with a constructor it also beats hand-hashing mapping slots
    /// into `vm.store`, where a wrong slot silently makes every assertion vacuous.
    function deployAccountWithArgs(string memory name, bytes memory args)
        internal
        returns (address account)
    {
        string memory path = string.concat(vm.projectRoot(), "/out-frame/", name, "/", name, ".bin");
        bytes memory initcode =
            abi.encodePacked(vm.parseBytes(string.concat("0x", vm.readFile(path))), args);
        assembly {
            account := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(account != address(0), string.concat("deploy failed for ", name));
    }

    /// Fully initialized empty host-supplied POST_TX tooling-fixture trace.
    function emptyTrace() internal pure returns (IFrameVm.FrameTxTrace memory trace) {
        trace.balanceDiffs = new IFrameVm.FrameTxBalanceDiff[](0);
        trace.storageDiffs = new IFrameVm.FrameTxStorageDiff[](0);
        trace.deployedContracts = new IFrameVm.FrameTxDeployedContract[](0);
        trace.accountDiffs = new IFrameVm.FrameTxAccountDiff[](0);
        trace.events = new IFrameVm.FrameTxEvent[](0);
    }

    /// Synthetic fixture key list `[0]` used when modeling the baseline scalar nonce.
    function legacyNonceKeys() internal pure returns (uint256[] memory keys) {
        keys = new uint256[](1);
    }

    /// A single-frame VERIFY context: the common shape for validating an account.
    function verifyContext(address account, uint64 approvableScopes, bytes32 sigHash)
        internal
        pure
        returns (IFrameVm.FrameTx memory)
    {
        uint256[] memory nonceKeys = legacyNonceKeys();
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
            legacyNonce: 0,
            nonceKeys: nonceKeys,
            nonceKeysHash: LEGACY_NONCE_KEYS_HASH,
            sigHash: sigHash,
            maxCost: 0,
            maxPriorityFeePerGas: 0,
            maxFeePerGas: 0,
            maxFeePerBlobGas: 0,
            blobCount: 0,
            frameIndex: 0,
            frames: frames,
            signatures: new IFrameVm.FrameTxSignature[](0),
            recentRootReferences: new IFrameVm.FrameTxRecentRootReference[](0),
            trace: emptyTrace(),
            approvableScopes: approvableScopes
        });
    }

    /// Synthetic secp256k1 entry modeling the normative canonical-hash case.
    /// `setFrameTx` trusts these fields and performs no cryptographic verification.
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

    /// Calls the account with the current frame's own data, as ENTRY_POINT would.
    ///
    /// The no-calldata form above reaches `receive()` on any account that has one,
    /// which succeeds whatever the policy decides; an account behind a Solidity
    /// dispatcher must be driven through this form or every assertion about it is
    /// vacuous. Requiring a selector is what stops an unset `data` from silently
    /// degrading back into that.
    function callAccountFrame(address account, IFrameVm.FrameTx memory ctx)
        internal
        returns (bool ok)
    {
        bytes memory data = ctx.frames[ctx.frameIndex].data;
        require(data.length >= 4, "frame data must carry a selector");
        (ok,) = account.call(data);
    }

    /// `assertApproves` driving the account with its frame data.
    function assertApprovesFrame(address account, IFrameVm.FrameTx memory ctx, string memory reason)
        internal
    {
        fvm.setFrameTx(ctx);
        assertTrue(callAccountFrame(account, ctx), reason);
        fvm.clearFrameTx();
    }

    /// `assertRefuses` driving the account with its frame data.
    function assertRefusesFrame(address account, IFrameVm.FrameTx memory ctx, string memory reason)
        internal
    {
        fvm.setFrameTx(ctx);
        assertFalse(callAccountFrame(account, ctx), reason);
        fvm.clearFrameTx();
    }
}
