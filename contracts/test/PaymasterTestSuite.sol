// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";
import {IFrameAccount} from "../src/accounts/IFrameAccount.sol";
import {Base64Url} from "../src/crypto/Base64Url.sol";

/// Reusable conformance tests for a paymaster.
///
/// A concrete paymaster test supplies its deployed target, the signature entries
/// that authorise sponsorship, and the calldata which selects those entries. Its
/// `setUp` must leave the paymaster able to approve `_paymasterTestMaxCost()`.
///
/// Each positive case drives both VERIFY frames from the same three-frame
/// transaction fixture:
///
///   account VERIFY (EXECUTION) -> paymaster VERIFY (PAYMENT) -> SENDER
///
/// Each account case supplies a signature prefix and explicit selected indices;
/// the paymaster entries are appended after that prefix and receive the matching
/// dynamically shifted indices. This proves that neither frame assumes its
/// signatures begin at zero.
///
/// These are opcode-level approval tests, not end-to-end transaction accounting
/// tests. `approvableScopes` pins the only scope that may succeed in each call,
/// but the Foundry frame fixture does not prove an ETH debit or balance transfer.
abstract contract PaymasterTestSuite is FrameTest {
    address private constant DEFAULT_PORTABLE_YUL_ACCOUNT = address(0xA110);
    address private constant DEFAULT_BUILTIN_YUL_ACCOUNT = address(0xA111);
    address private constant DEFAULT_SENDER_TARGET = address(0x7043);
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
    uint256 private constant P256_N =
        0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    string private constant WEBAUTHN_RP_ID = "wallet.example";
    string private constant WEBAUTHN_ORIGIN = "https://wallet.example";

    struct SponsoredAccountCase {
        address account;
        /// Account-side entries already positioned at their transaction indices.
        IFrameVm.FrameTxSignature[] signaturePrefix;
        /// Entries from `signaturePrefix` selected by validate(uint256[]).
        uint256[] accountSignatureIndices;
    }

    // Fresh runtimes for contracts/src/accounts/account.yul and
    // contracts/src/accounts/account-builtins.yul, respectively. Both expose
    // validate(uint256[]) and read their sole selected index from calldata.
    bytes private constant PORTABLE_YUL_RUNTIME =
        hex"36600557005b606436146010575f5ffd5b6325b904945f3560e01c146022575f5ffd5b602060043514602f575f5ffd5b600160243514603c575f5ffd5b6044355f81b4600282b415600ab0600681b3806056575f5ffd5b82845f54141615606557805f5faa5b5f5ffd";
    bytes private constant BUILTIN_YUL_RUNTIME =
        hex"3615606557606436036061576325b904945f3560e01c03605d5760206004350360595760016024350360555760443560025f82b491b4156006600ab0b39182156051575f541416604d575f80fd5b5f80aa5b5f80fd5b5f80fd5b5f80fd5b5f80fd5b5f80fd5b00";

    /// The deployed paymaster under test.
    function _paymasterUnderTest() internal view virtual returns (address);

    /// Override these if the paymaster under test reserves one of the default
    /// fixture addresses.
    function _paymasterSuitePortableYulAccount() internal view virtual returns (address) {
        return DEFAULT_PORTABLE_YUL_ACCOUNT;
    }

    function _paymasterSuiteBuiltinYulAccount() internal view virtual returns (address) {
        return DEFAULT_BUILTIN_YUL_ACCOUNT;
    }

    function _paymasterSuiteSenderTarget() internal view virtual returns (address) {
        return DEFAULT_SENDER_TARGET;
    }

    /// The native or contract-verified entries that satisfy the paymaster's policy.
    function _paymasterTestSignatures()
        internal
        view
        virtual
        returns (IFrameVm.FrameTxSignature[] memory);

    /// Calldata for the paymaster VERIFY frame, selecting its envelope entries.
    function _paymasterTestCall(uint256[] memory signatureIndices)
        internal
        view
        virtual
        returns (bytes memory);

    /// A max-cost fixture accepted by the configured paymaster.
    function _paymasterTestMaxCost() internal view virtual returns (uint256);

    /// Optional setup for sender-specific allowlists or proofs. It runs after
    /// the account is deployed and before the shared transaction fixture is
    /// built. Signature hooks should otherwise remain stable during one case.
    function _preparePaymasterForAccount(address account) internal virtual {}

    function _differentFromPaymaster(uint160 candidate) private view returns (address result) {
        result = address(candidate);
        IFrameVm.FrameTxSignature[] memory paymasterSignatures = _paymasterTestSignatures();
        bool collided = true;
        while (collided) {
            collided = false;
            for (uint256 i = 0; i < paymasterSignatures.length; ++i) {
                if (result == paymasterSignatures[i].signer) {
                    result = address(uint160(result) + 1);
                    collided = true;
                    break;
                }
            }
        }
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

    function _singleIndex(uint256 index) private pure returns (uint256[] memory indices) {
        indices = new uint256[](1);
        indices[0] = index;
    }

    function _multisigIndices() private pure returns (uint256[] memory indices) {
        indices = new uint256[](2);
        indices[0] = 1;
        indices[1] = 2;
    }

    function _paymasterIndices(uint256 accountPrefixLength)
        private
        view
        returns (uint256[] memory indices)
    {
        uint256 count = _paymasterTestSignatures().length;
        indices = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            indices[i] = accountPrefixLength + i;
        }
    }

    function _sharedSignatures(IFrameVm.FrameTxSignature[] memory accountPrefix)
        private
        view
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        IFrameVm.FrameTxSignature[] memory paymasterSignatures = _paymasterTestSignatures();
        signatures =
            new IFrameVm.FrameTxSignature[](accountPrefix.length + paymasterSignatures.length);
        for (uint256 i = 0; i < accountPrefix.length; ++i) {
            signatures[i] = accountPrefix[i];
        }
        for (uint256 i = 0; i < paymasterSignatures.length; ++i) {
            signatures[accountPrefix.length + i] = paymasterSignatures[i];
        }
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
            data: abi.encodeWithSelector(
                IFrameAccount.validate.selector, accountCase.accountSignatureIndices
            ),
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
            data: _paymasterTestCall(_paymasterIndices(prefixLength)),
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

        uint256[] memory nonceKeys = legacyNonceKeys();
        ctx = IFrameVm.FrameTx({
            sender: accountCase.account,
            nonce: 0,
            legacyNonce: 0,
            nonceKeys: nonceKeys,
            nonceKeysHash: LEGACY_NONCE_KEYS_HASH,
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

    function _defaultAccountCase(address account, uint256[] memory selectedIndices)
        private
        view
        returns (SponsoredAccountCase memory accountCase)
    {
        IFrameVm.FrameTxSignature[] memory prefix = new IFrameVm.FrameTxSignature[](3);
        prefix[0] = secpSig(_suiteDistractor());
        prefix[1] = secpSig(_suiteOwnerA());
        prefix[2] = secpSig(_suiteOwnerB());
        accountCase = SponsoredAccountCase({
            account: account, signaturePrefix: prefix, accountSignatureIndices: selectedIndices
        });
    }

    function _ownerAccountCase() private returns (SponsoredAccountCase memory accountCase) {
        address account = deployAccountWithArgs("OwnerAccount", abi.encode(_suiteOwnerA()));
        return _defaultAccountCase(account, _singleIndex(1));
    }

    function _multisigAccountCase() private returns (SponsoredAccountCase memory accountCase) {
        address[] memory owners = new address[](3);
        owners[0] = _suiteOwnerA();
        owners[1] = _suiteOwnerB();
        owners[2] = address(0x3333);
        address account = deployAccountWithArgs("MultisigAccount", abi.encode(owners, uint256(2)));
        return _defaultAccountCase(account, _multisigIndices());
    }

    function _sessionKeyAccountCase() private returns (SponsoredAccountCase memory accountCase) {
        // The suite deliberately uses the owner path, which is unconditional;
        // session-key expiry and allowlist behavior belongs to the account suite.
        address account = deployAccountWithArgs("SessionKeyAccount", abi.encode(_suiteOwnerA()));
        return _defaultAccountCase(account, _singleIndex(1));
    }

    function _p256ResolvedSigner() private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(P256_QX, P256_QY)))));
    }

    function _p256AccountCase() private returns (SponsoredAccountCase memory accountCase) {
        address account = deployAccountWithArgs("P256Account", abi.encode(P256_QX, P256_QY));

        // Unlike the legacy cases, this prefix intentionally has length two.
        // The paymaster indices must therefore begin at two, proving the append
        // logic is derived from the case rather than a fixed offset of three.
        IFrameVm.FrameTxSignature[] memory prefix = new IFrameVm.FrameTxSignature[](2);
        address trustedSigner = _p256ResolvedSigner();
        prefix[0] = p256Sig(_differentFromPaymasterAnd(trustedSigner, 0xD256));
        prefix[1] = p256Sig(trustedSigner);
        accountCase = SponsoredAccountCase({
            account: account, signaturePrefix: prefix, accountSignatureIndices: _singleIndex(1)
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
            account: account, signaturePrefix: prefix, accountSignatureIndices: _singleIndex(1)
        });
    }

    function _installYulAccount(address account, bytes memory runtime) private {
        vm.etch(account, runtime);
        vm.store(account, bytes32(0), bytes32(uint256(uint160(_suiteOwnerA()))));
    }

    function test_paymasterConformance_sponsorsOwnerAccount() public {
        SponsoredAccountCase memory accountCase = _ownerAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "owner account must approve execution from shifted signature index 1",
            "paymaster must sponsor the owner account from indices beginning at 3"
        );
    }

    function test_paymasterConformance_sponsorsMultisigAccount() public {
        SponsoredAccountCase memory accountCase = _multisigAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "multisig must approve execution from shifted signature indices 1 and 2",
            "paymaster must sponsor the multisig account from indices beginning at 3"
        );
    }

    function test_paymasterConformance_sponsorsSessionKeyAccountViaOwner() public {
        SponsoredAccountCase memory accountCase = _sessionKeyAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "session-key account owner must approve execution from shifted signature index 1",
            "paymaster must sponsor the session-key account from indices beginning at 3"
        );
    }

    function test_paymasterConformance_sponsorsPortableYulAccount() public {
        address account = _paymasterSuitePortableYulAccount();
        _installYulAccount(account, PORTABLE_YUL_RUNTIME);
        _preparePaymasterForAccount(account);
        SponsoredAccountCase memory accountCase = _defaultAccountCase(account, _singleIndex(1));
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "portable Yul account must approve execution from shifted signature index 1",
            "paymaster must sponsor the portable Yul account from indices beginning at 3"
        );
    }

    function test_paymasterConformance_sponsorsBuiltinYulAccount() public {
        address account = _paymasterSuiteBuiltinYulAccount();
        _installYulAccount(account, BUILTIN_YUL_RUNTIME);
        _preparePaymasterForAccount(account);
        SponsoredAccountCase memory accountCase = _defaultAccountCase(account, _singleIndex(1));
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "builtin Yul account must approve execution from shifted signature index 1",
            "paymaster must sponsor the builtin Yul account from indices beginning at 3"
        );
    }

    function test_paymasterConformance_sponsorsP256Account() public {
        SponsoredAccountCase memory accountCase = _p256AccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "P256 account must approve execution from synthetic scheme-2 signature index 1",
            "paymaster must sponsor the P256 account from indices beginning at 2"
        );
    }

    function test_paymasterConformance_sponsorsWebAuthnAccount() public {
        SponsoredAccountCase memory accountCase = _webAuthnAccountCase();
        _preparePaymasterForAccount(accountCase.account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(accountCase),
            "WebAuthn account must approve execution from configured credential at index 1",
            "paymaster must sponsor the WebAuthn account from indices beginning at 2"
        );
    }

    function test_paymasterConformance_wrongSelectedPaymasterIndexIsRefused() public {
        SponsoredAccountCase memory accountCase = _ownerAccountCase();
        address account = accountCase.account;
        _preparePaymasterForAccount(account);
        uint256 paymasterSignatureCount = _paymasterTestSignatures().length;
        if (paymasterSignatureCount == 0) return;

        IFrameVm.FrameTx memory ctx = _sponsoredContext(accountCase);

        // Prove the account route remains valid, then misroute the paymaster to
        // that account entry instead of its own entries after the account prefix.
        ctx.frameIndex = 0;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(account, ctx, "account must require its execution approval scope");

        ctx.approvableScopes = SCOPE_EXECUTION;
        assertApprovesFrame(account, ctx, "account signature index 1 must remain valid");

        uint256[] memory wrongIndices = new uint256[](paymasterSignatureCount);
        for (uint256 i = 0; i < wrongIndices.length; ++i) {
            wrongIndices[i] = accountCase.accountSignatureIndices[0];
        }
        ctx.frames[1].data = _paymasterTestCall(wrongIndices);
        ctx.frames[0].status = 1;
        ctx.frameIndex = 1;
        ctx.approvableScopes = SCOPE_PAYMENT;
        assertRefusesFrame(
            _paymasterUnderTest(),
            ctx,
            "paymaster must not treat the account-selected signature as its authorisation"
        );
    }
}
