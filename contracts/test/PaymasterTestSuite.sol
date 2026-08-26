// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";
import {Base64Url} from "../src/crypto/Base64Url.sol";

import {Kernel} from "kernel-v3.3/Kernel.sol";
import {KernelFactory} from "kernel-v3.3/factory/KernelFactory.sol";
import {IHook, IValidator} from "kernel-v3.3/interfaces/IERC7579Modules.sol";
import {ValidationId} from "kernel-v3.3/types/Types.sol";
import {ValidatorLib} from "kernel-v3.3/utils/ValidationTypeLib.sol";

/// Reusable conformance tests for a paymaster.
///
/// A concrete paymaster test supplies its deployed target, the signature entry
/// that authorises sponsorship, and the calldata which selects that entry. Its
/// `setUp` must leave the paymaster able to approve `_paymasterTestMaxCost()`.
///
/// Each positive case drives both VERIFY frames from the same three-frame
/// transaction fixture:
///
///   account VERIFY (EXECUTION) -> paymaster VERIFY (PAYMENT) -> SENDER
///
/// Each account case supplies a signature prefix and its exact validation calldata;
/// the paymaster entry is appended after that prefix and receives the matching
/// dynamically shifted index. This proves that neither frame assumes its
/// signatures begin at zero.
///
/// These are opcode-level approval tests, not end-to-end transaction accounting
/// tests. `approvableScopes` pins the only scope that may succeed in each call,
/// but the Foundry frame fixture does not prove an ETH debit or balance transfer.
abstract contract PaymasterTestSuite is FrameTest {
    address private constant DEFAULT_SENDER_TARGET = address(0x7043);
    address private constant KERNEL_V33_ENTRY_POINT = address(0x4337);
    bytes32 private constant PAYMASTER_SUITE_SIG_HASH = bytes32(uint256(0xf00d));

    // P256 generator point (the public key for private scalar 1). P256Account's
    // constructor derives the same identity that SIGPARAM exposes for the
    // protocol entry: keccak256(qx || qy)[12:].
    bytes32 private constant P256_QX =
        0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296;
    bytes32 private constant P256_QY =
        0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5;

    uint8 private constant WEBAUTHN_FLAGS_UP_UV = 0x05;
    uint256 private constant WEBAUTHN_CREDENTIAL_KEY =
        0x123456789abcdef123456789abcdef123456789abcdef123456789abcdef1234;
    uint256 private constant WEBAUTHN_OTHER_CREDENTIAL_KEY =
        0x23456789abcdef123456789abcdef123456789abcdef123456789abcdef12345;
    uint256 private constant EOA_7702_AUTHORITY_KEY = 0x7702f00d;
    uint256 private constant FRAME_KERNEL_P256_SCHEME = 2;
    uint256 private constant P256_N =
        0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    string private constant WEBAUTHN_RP_ID = "wallet.example";
    string private constant WEBAUTHN_ORIGIN = "https://wallet.example";

    struct SponsoredAccountCase {
        address account;
        /// Account-side entries already positioned at their transaction indices.
        IFrameVm.FrameTxSignature[] signaturePrefix;
        /// Exact account VERIFY calldata; only multisig carries a uint256[].
        bytes accountCallData;
        /// One valid account entry reused by the paymaster misrouting negative.
        uint256 accountSignatureIndex;
    }

    /// The deployed paymaster under test.
    function _paymasterUnderTest() internal view virtual returns (address);

    function _paymasterSuiteSenderTarget() internal view virtual returns (address) {
        return DEFAULT_SENDER_TARGET;
    }

    /// The native or contract-verified entry that satisfies the paymaster's policy.
    function _paymasterTestSignature()
        internal
        view
        virtual
        returns (IFrameVm.FrameTxSignature memory);

    /// Calldata for the paymaster VERIFY frame, selecting its envelope entry.
    function _paymasterTestCall(uint256 signatureIndex) internal view virtual returns (bytes memory);

    /// A max-cost fixture accepted by the configured paymaster.
    function _paymasterTestMaxCost() internal view virtual returns (uint256);

    /// Optional setup for sender-specific allowlists or proofs. It runs after
    /// the account is deployed and before the shared transaction fixture is
    /// built. Signature hooks should otherwise remain stable during one case.
    function _preparePaymasterForAccount(address account) internal virtual {}

    function _differentFromPaymaster(uint160 candidate) private view returns (address result) {
        result = address(candidate);
        address paymasterSigner = _paymasterTestSignature().signer;
        while (result == paymasterSigner) result = address(uint160(result) + 1);
    }

    function _suiteOwnerA() private view returns (address) {
        return _differentFromPaymaster(0x1111);
    }

    function _suiteOwnerB() private view returns (address) {
        return _differentFromPaymaster(0x2222);
    }

    function _suiteDistractor() private view returns (address) {
        return _differentFromPaymaster(0xD157);
    }

    function _differentFromPaymasterAnd(address additionallyAvoided, uint160 candidate)
        private
        view
        returns (address result)
    {
        result = _differentFromPaymaster(candidate);
        while (result == additionallyAvoided) {
            result = _differentFromPaymaster(uint160(result) + 1);
        }
    }

    function _singleAccountCall(uint256 signatureIndex) private pure returns (bytes memory) {
        return abi.encodeWithSignature("validate(uint256)", signatureIndex);
    }

    function _multisigIndices() private pure returns (uint256[] memory indices) {
        indices = new uint256[](2);
        indices[0] = 1;
        indices[1] = 2;
    }

    function _sharedSignatures(IFrameVm.FrameTxSignature[] memory accountPrefix)
        private
        view
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](accountPrefix.length + 1);
        for (uint256 i = 0; i < accountPrefix.length; ++i) {
            signatures[i] = accountPrefix[i];
        }
        signatures[accountPrefix.length] = _paymasterTestSignature();
    }

    function _sponsoredContext(SponsoredAccountCase memory accountCase)
        private
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        uint256 prefixLength = accountCase.signaturePrefix.length;
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](3);
        frames[0] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(SCOPE_EXECUTION),
            target: accountCase.account,
            gasLimit: 300_000,
            stateGasLimit: 0,
            value: 0,
            data: accountCase.accountCallData,
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        frames[1] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(SCOPE_PAYMENT),
            target: _paymasterUnderTest(),
            gasLimit: 200_000,
            stateGasLimit: 0,
            value: 0,
            data: _paymasterTestCall(prefixLength),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        frames[2] = IFrameVm.FrameTxFrame({
            mode: MODE_SENDER,
            flags: 0,
            target: _paymasterSuiteSenderTarget(),
            gasLimit: 100_000,
            stateGasLimit: 0,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", address(0xBEEF), uint256(1)),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });

        ctx = IFrameVm.FrameTx({
            sender: accountCase.account,
            nonce: 0,
            stateGasLeft: 0,
            sigHash: PAYMASTER_SUITE_SIG_HASH,
            maxCost: _paymasterTestMaxCost(),
            maxPriorityFeePerGas: 0,
            maxFeePerGas: 0,
            maxFeePerBlobGas: 0,
            blobCount: 0,
            frameIndex: 0,
            frames: frames,
            signatures: _sharedSignatures(accountCase.signaturePrefix),
            recentRootReferences: new IFrameVm.FrameTxRecentRootReference[](0),
            trace: emptyTrace(),
            approvableScopes: SCOPE_EXECUTION
        });
    }

    function _assertAccountThenPaymasterApprove(
        IFrameVm.FrameTx memory ctx,
        string memory accountReason,
        string memory paymasterReason
    ) private {
        assertEq(ctx.frames[0].flags, SCOPE_EXECUTION, "account frame scope must be exact");
        assertEq(ctx.frames[1].flags, SCOPE_PAYMENT, "paymaster frame scope must be exact");

        // First deny all approvals while keeping the frame unchanged. A plain
        // RETURN would still succeed, so this refusal proves the positive call
        // below actually reaches APPROVE(EXECUTION).
        ctx.frameIndex = 0;
        ctx.frames[0].status = 0;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(ctx.sender, ctx, "account must require its execution approval scope");

        ctx.approvableScopes = SCOPE_EXECUTION;
        assertApprovesFrame(ctx.sender, ctx, accountReason);

        // setFrameTx is a per-call fixture. The preceding status is documentary:
        // this cheatcode does not persist sender_approved from the account call.
        // The NONE probe still proves that the paymaster's success reaches
        // APPROVE(PAYMENT), rather than an ordinary return.
        ctx.frameIndex = 1;
        ctx.frames[0].status = 1;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(
            _paymasterUnderTest(), ctx, "paymaster must require its payment approval scope"
        );

        ctx.approvableScopes = SCOPE_PAYMENT;
        assertApprovesFrame(_paymasterUnderTest(), ctx, paymasterReason);
    }

    function _defaultAccountCase(address account, bytes memory accountCallData)
        private
        view
        returns (SponsoredAccountCase memory accountCase)
    {
        IFrameVm.FrameTxSignature[] memory prefix = new IFrameVm.FrameTxSignature[](3);
        prefix[0] = secpSig(_suiteDistractor());
        prefix[1] = secpSig(_suiteOwnerA());
        prefix[2] = secpSig(_suiteOwnerB());
        accountCase = SponsoredAccountCase({
            account: account,
            signaturePrefix: prefix,
            accountCallData: accountCallData,
            accountSignatureIndex: 1
        });
    }

    function _ownerAccountCase() private returns (SponsoredAccountCase memory accountCase) {
        address account = deployAccountWithArgs("OwnerAccount", abi.encode(_suiteOwnerA()));
        return _defaultAccountCase(account, _singleAccountCall(1));
    }

    function _multisigAccountCase() private returns (SponsoredAccountCase memory accountCase) {
        address[] memory owners = new address[](3);
        owners[0] = _suiteOwnerA();
        owners[1] = _suiteOwnerB();
        owners[2] = address(0x3333);
        address account = deployAccountWithArgs("MultisigAccount", abi.encode(owners, uint256(2)));
        return _defaultAccountCase(
            account, abi.encodeWithSignature("validate(uint256[])", _multisigIndices())
        );
    }

    function _sessionKeyAccountCase() private returns (SponsoredAccountCase memory accountCase) {
        // The suite deliberately uses the owner path, which is unconditional;
        // session-key expiry and allowlist behavior belongs to the account suite.
        address account = deployAccountWithArgs("SessionKeyAccount", abi.encode(_suiteOwnerA()));
        return _defaultAccountCase(account, _singleAccountCall(1));
    }

    function _p256ResolvedSigner() private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(P256_QX, P256_QY)))));
    }

    function _p256AccountCase() private returns (SponsoredAccountCase memory accountCase) {
        address account = deployAccountWithArgs("P256Account", abi.encode(P256_QX, P256_QY));

        // Unlike the legacy cases, this prefix intentionally has length two.
        // The paymaster index must therefore be two, proving the append
        // logic is derived from the case rather than a fixed offset of three.
        IFrameVm.FrameTxSignature[] memory prefix = new IFrameVm.FrameTxSignature[](2);
        address trustedSigner = _p256ResolvedSigner();
        prefix[0] = p256Sig(_differentFromPaymasterAnd(trustedSigner, 0xD256));
        prefix[1] = p256Sig(trustedSigner);
        accountCase = SponsoredAccountCase({
            account: account,
            signaturePrefix: prefix,
            accountCallData: _singleAccountCall(1),
            accountSignatureIndex: 1
        });
    }

    function _frameKernelAccountCase() private returns (SponsoredAccountCase memory accountCase) {
        address trustedSigner = _p256ResolvedSigner();
        address account = deployAccountWithArgs(
            "FrameKernel", abi.encode(FRAME_KERNEL_P256_SCHEME, trustedSigner)
        );

        // Exercise FrameKernel's native-P256 route here. Its compact WebAuthn-P256
        // route is covered by FrameKernelWebAuthnTest using real P256 signatures.
        IFrameVm.FrameTxSignature[] memory prefix = new IFrameVm.FrameTxSignature[](2);
        prefix[0] = p256Sig(_differentFromPaymasterAnd(trustedSigner, 0xF256));
        prefix[1] = p256Sig(trustedSigner);
        accountCase = SponsoredAccountCase({
            account: account,
            signaturePrefix: prefix,
            accountCallData: _singleAccountCall(1),
            accountSignatureIndex: 1
        });
    }

    function _webAuthnClientData() private pure returns (bytes memory) {
        return abi.encodePacked(
            '{"type":"webauthn.get","challenge":"',
            Base64Url.encode32(PAYMASTER_SUITE_SIG_HASH),
            '","origin":"',
            WEBAUTHN_ORIGIN,
            '","crossOrigin":false}'
        );
    }

    function _webAuthnAssertion(uint256 privateKey, bytes32 rpIdHash)
        private
        pure
        returns (bytes memory)
    {
        bytes memory authenticatorData =
            abi.encodePacked(rpIdHash, bytes1(WEBAUTHN_FLAGS_UP_UV), bytes4(0));
        bytes memory clientDataJSON = _webAuthnClientData();
        bytes32 digest = sha256(abi.encodePacked(authenticatorData, sha256(clientDataJSON)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, digest);

        // Keep the witness canonical even if a signer implementation returns
        // the mathematically equivalent high-s form.
        if (uint256(s) > P256_N / 2) s = bytes32(P256_N - uint256(s));
        return abi.encode(r, s, authenticatorData, clientDataJSON);
    }

    function _webAuthnAccountCase() private returns (SponsoredAccountCase memory accountCase) {
        (uint256 qx, uint256 qy) = vm.publicKeyP256(WEBAUTHN_CREDENTIAL_KEY);
        bytes32 rpIdHash = sha256(bytes(WEBAUTHN_RP_ID));
        bytes32 originHash = keccak256(bytes(WEBAUTHN_ORIGIN));
        address account = deployAccountWithArgs(
            "WebAuthnAccount", abi.encode(bytes32(qx), bytes32(qy), rpIdHash, originHash, true)
        );

        // Both entries are well-formed, same-scheme WebAuthn assertions. Only
        // index one uses the account's configured credential, proving that the
        // account follows its explicit route and enforces credential identity.
        IFrameVm.FrameTxSignature[] memory prefix = new IFrameVm.FrameTxSignature[](2);
        prefix[0] = arbitrarySig(_webAuthnAssertion(WEBAUTHN_OTHER_CREDENTIAL_KEY, rpIdHash));
        prefix[1] = arbitrarySig(_webAuthnAssertion(WEBAUTHN_CREDENTIAL_KEY, rpIdHash));
        accountCase = SponsoredAccountCase({
            account: account,
            signaturePrefix: prefix,
            accountCallData: _singleAccountCall(1),
            accountSignatureIndex: 1
        });
    }

    function _kernelV33AccountCase() private returns (SponsoredAccountCase memory accountCase) {
        address rootValidator = deployAccountWithArgs("ECDSAValidator", bytes(""));
        address legacyImplementation =
            deployAccountWithArgs("Kernel", abi.encode(KERNEL_V33_ENTRY_POINT));
        address frameImplementation = deployAccountWithArgs(
            "KernelV33FrameAccount", abi.encode(legacyImplementation, rootValidator)
        );
        address factory = deployAccountWithArgs("KernelFactory", abi.encode(legacyImplementation));

        ValidationId root = ValidatorLib.validatorToIdentifier(IValidator(rootValidator));
        bytes[] memory initConfig = new bytes[](0);
        bytes memory initialization = abi.encodeCall(
            Kernel.initialize,
            (root, IHook(address(0)), abi.encodePacked(_suiteOwnerA()), bytes(""), initConfig)
        );
        address account = KernelFactory(factory)
            .createAccount(
                initialization, keccak256(abi.encode("paymaster-suite-kernel-v3.3", address(this)))
            );

        vm.prank(KERNEL_V33_ENTRY_POINT);
        Kernel(payable(account)).upgradeTo(frameImplementation);
        return _defaultAccountCase(account, _singleAccountCall(1));
    }

    function _eoa7702AccountCase() private returns (SponsoredAccountCase memory accountCase) {
        uint256 authorityKey = EOA_7702_AUTHORITY_KEY;
        address authority = vm.addr(authorityKey);
        address paymasterSigner = _paymasterTestSignature().signer;
        while (authority == paymasterSigner) authority = vm.addr(++authorityKey);

        address implementation = deployAccountWithArgs("EOA7702FrameAccount", bytes(""));
        vm.signAndAttachDelegation(implementation, authorityKey);

        IFrameVm.FrameTxSignature[] memory prefix = new IFrameVm.FrameTxSignature[](3);
        prefix[0] = secpSig(_differentFromPaymasterAnd(authority, 0xD7702));
        prefix[1] = secpSig(authority);
        prefix[2] = secpSig(_differentFromPaymasterAnd(authority, 0xE7702));
        accountCase = SponsoredAccountCase({
            account: authority,
            signaturePrefix: prefix,
            accountCallData: _singleAccountCall(1),
            accountSignatureIndex: 1
        });
    }

    function test_paymasterConformance_sponsorsOwnerAccount() public {
        SponsoredAccountCase memory accountCase = _ownerAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "owner account must approve execution from shifted signature index 1",
            "paymaster must sponsor the owner account from shifted index 3"
        );
    }

    function test_paymasterConformance_sponsorsMultisigAccount() public {
        SponsoredAccountCase memory accountCase = _multisigAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "multisig must approve execution from shifted signature indices 1 and 2",
            "paymaster must sponsor the multisig account from shifted index 3"
        );
    }

    function test_paymasterConformance_sponsorsSessionKeyAccountViaOwner() public {
        SponsoredAccountCase memory accountCase = _sessionKeyAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "session-key account owner must approve execution from shifted signature index 1",
            "paymaster must sponsor the session-key account from shifted index 3"
        );
    }

    function test_paymasterConformance_sponsorsP256Account() public {
        SponsoredAccountCase memory accountCase = _p256AccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "P256 account must approve execution from synthetic scheme-2 signature index 1",
            "paymaster must sponsor the P256 account from shifted index 2"
        );
    }

    function test_paymasterConformance_sponsorsFrameKernel() public {
        SponsoredAccountCase memory accountCase = _frameKernelAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "FrameKernel must approve execution from native P256 signature index 1",
            "paymaster must sponsor FrameKernel from shifted index 2"
        );
    }

    function test_paymasterConformance_sponsorsWebAuthnAccount() public {
        SponsoredAccountCase memory accountCase = _webAuthnAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "WebAuthn account must approve execution from configured credential at index 1",
            "paymaster must sponsor the WebAuthn account from shifted index 2"
        );
    }

    function test_paymasterConformance_sponsorsMigratedKernelV33Account() public {
        SponsoredAccountCase memory accountCase = _kernelV33AccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "migrated Kernel v3.3 account must approve execution from shifted index 1",
            "paymaster must sponsor the migrated Kernel account from shifted index 3"
        );
    }

    function test_paymasterConformance_sponsorsEoa7702DelegatedAccount() public {
        SponsoredAccountCase memory accountCase = _eoa7702AccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "EIP-7702 authority must approve execution from shifted index 1",
            "paymaster must sponsor the delegated EOA from shifted index 3"
        );
    }

    function test_paymasterConformance_wrongSelectedPaymasterIndexIsRefused() public {
        SponsoredAccountCase memory accountCase = _ownerAccountCase();
        address account = accountCase.account;
        _preparePaymasterForAccount(account);
        IFrameVm.FrameTx memory ctx = _sponsoredContext(accountCase);

        // Prove the account route remains valid, then misroute the paymaster to
        // that account entry instead of its own entry after the account prefix.
        ctx.frameIndex = 0;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(account, ctx, "account must require its execution approval scope");

        ctx.approvableScopes = SCOPE_EXECUTION;
        assertApprovesFrame(account, ctx, "account signature index 1 must remain valid");

        ctx.frames[1].data = _paymasterTestCall(accountCase.accountSignatureIndex);
        ctx.frames[0].status = 1;
        ctx.frameIndex = 1;
        ctx.approvableScopes = SCOPE_PAYMENT;
        assertRefusesFrame(
            _paymasterUnderTest(),
            ctx,
            "paymaster must not treat the account-selected signature as its authorisation"
        );
    }

    /// The shared paymaster route must fail closed when the selected sponsor
    /// entry is an ARBITRARY signature with a malformed policy witness. Native
    /// paymasters reject the scheme; WebAuthn rejects the malformed assertion.
    function test_paymasterConformance_rejectsMalformedArbitrarySignature() public {
        SponsoredAccountCase memory accountCase = _ownerAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        IFrameVm.FrameTx memory ctx = _sponsoredContext(accountCase);
        uint256 paymasterSignatureIndex = ctx.signatures.length - 1;
        ctx.signatures[paymasterSignatureIndex] = arbitrarySig(hex"deadbeef");
        ctx.frames[0].status = 1;
        ctx.frameIndex = 1;
        ctx.approvableScopes = SCOPE_PAYMENT;

        assertRefusesFrame(
            _paymasterUnderTest(),
            ctx,
            "a malformed ARBITRARY signature must not authorize sponsorship"
        );
    }

    /// Native raw bytes are verified before this opcode-level fixture runs.
    /// Exercise the contract-visible failure mode for each native scheme by
    /// routing a protocol-resolved identity that is not the configured sponsor.
    function test_paymasterConformance_rejectsWrongSecp256k1Signature() public {
        _assertWrongNativeSignatureIsRefused(
            1, "a wrong secp256k1 signature must not authorize sponsorship"
        );
    }

    function test_paymasterConformance_rejectsWrongP256Signature() public {
        _assertWrongNativeSignatureIsRefused(
            2, "a wrong P256 signature must not authorize sponsorship"
        );
    }

    function _assertWrongNativeSignatureIsRefused(uint8 scheme, string memory reason) private {
        SponsoredAccountCase memory accountCase = _ownerAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        IFrameVm.FrameTx memory ctx = _sponsoredContext(accountCase);
        uint256 paymasterSignatureIndex = ctx.signatures.length - 1;
        address stranger = _differentFromPaymaster(uint160(0xBAD100 + scheme));

        if (scheme == 1) {
            ctx.signatures[paymasterSignatureIndex] = secpSig(stranger);
        } else if (scheme == 2) {
            ctx.signatures[paymasterSignatureIndex] = p256Sig(stranger);
        } else {
            revert("unsupported native test scheme");
        }

        ctx.frames[0].status = 1;
        ctx.frameIndex = 1;
        ctx.approvableScopes = SCOPE_PAYMENT;
        assertRefusesFrame(_paymasterUnderTest(), ctx, reason);
    }
}
