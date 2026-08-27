// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base64} from "solady/utils/Base64.sol";

import {AccountTestSuite} from "./AccountTestSuite.sol";
import {IFrameVm} from "./FrameTest.sol";
import {FrameKernel} from "../src/accounts/FrameKernel.sol";
import {IFrameAccount} from "../src/accounts/IFrameAccount.sol";
import {IFormatter} from "../src/formatters/IFormatter.sol";
import {WebAuthnFormatter} from "../src/formatters/WebAuthnFormatter.sol";

abstract contract FrameKernelTestBase is AccountTestSuite {
    uint8 internal constant SCHEME_ARBITRARY = 0;
    uint8 internal constant SCHEME_SECP256K1 = 1;
    uint8 internal constant SCHEME_P256 = 2;
    uint8 internal constant FLAGS_UP_UV = 0x05;
    uint256 internal constant CREDENTIAL_KEY =
        0x123456789abcdef123456789abcdef123456789abcdef123456789abcdef1234;
    uint256 internal constant OTHER_CREDENTIAL_KEY =
        0x23456789abcdef123456789abcdef123456789abcdef123456789abcdef12345;
    uint256 internal constant BOOTSTRAP_P256_KEY =
        0x34567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef12;
    uint256 internal constant P256_N =
        0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    bytes32 internal constant SUITE_CHALLENGE = bytes32(uint256(0x8141));
    string internal constant RP_ID = "wallet.example";
    string internal constant ORIGIN = "https://wallet.example";

    address internal account;
    bytes32 internal publicKeyX;
    bytes32 internal publicKeyY;
    address internal credentialSigner;
    bytes32 internal expectedRpIdHash;

    function accountUnderTest() internal view override returns (address) {
        return account;
    }

    function accountSuiteSigHash() internal pure override returns (bytes32) {
        return SUITE_CHALLENGE;
    }

    function _prepareCredential() internal {
        (uint256 qx, uint256 qy) = vm.publicKeyP256(CREDENTIAL_KEY);
        publicKeyX = bytes32(qx);
        publicKeyY = bytes32(qy);
        credentialSigner = _p256Signer(publicKeyX, publicKeyY);
        expectedRpIdHash = sha256(bytes(RP_ID));
    }

    function _p256Signer(bytes32 qx, bytes32 qy) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(qx, qy)))));
    }

    function _entry(uint8 scheme, address claimedSigner, bytes32 msgHash, bytes memory witness)
        internal
        pure
        returns (IFrameVm.FrameTxSignature memory)
    {
        return IFrameVm.FrameTxSignature({
            scheme: scheme, signer: claimedSigner, msgHash: msgHash, signature: witness
        });
    }

    function _validationCalldata(uint256 signatureIndex)
        internal
        view
        virtual
        returns (bytes memory)
    {
        return validationCalldata(signatureIndex);
    }

    function _contextFor(address subject, IFrameVm.FrameTxSignature memory signature, uint64 scope)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        ctx = verifyContext(subject, scope, SUITE_CHALLENGE);
        ctx.frames[0].data = _validationCalldata(0);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = signature;
    }

    function _authenticatorData(bytes32 rpHash, uint8 flags) internal pure returns (bytes memory) {
        return _authenticatorDataWithCounter(rpHash, flags, 0);
    }

    function _authenticatorDataWithCounter(bytes32 rpHash, uint8 flags, uint32 counter)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(rpHash, bytes1(flags), bytes4(counter));
    }

    function _formatterData(string memory origin, string memory assertionType, bool crossOrigin)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory prefix = abi.encodePacked('{"type":"', assertionType, '","challenge":"');
        bytes memory beforeCrossOrigin = abi.encodePacked('","origin":"', origin, '",');
        bytes memory suffix = abi.encodePacked(
            beforeCrossOrigin, '"crossOrigin":', crossOrigin ? "true" : "false", "}"
        );
        uint256 crossOriginIndex = prefix.length + 43 + beforeCrossOrigin.length;
        return abi.encode(prefix, suffix, uint256(1), crossOriginIndex);
    }

    function _validFormatterData() internal pure returns (bytes memory) {
        return _formatterData(ORIGIN, "webauthn.get", false);
    }

    function _formattedMessageHash(
        bytes32 challenge,
        bytes memory formatterData,
        bytes memory authenticatorData
    ) internal pure returns (bytes32) {
        (bytes memory clientDataPrefix, bytes memory clientDataSuffix,,) =
            abi.decode(formatterData, (bytes, bytes, uint256, uint256));
        bytes memory clientDataJSON = bytes.concat(
            clientDataPrefix,
            bytes(Base64.encode(abi.encode(challenge), true, true)),
            clientDataSuffix
        );
        return sha256(abi.encodePacked(authenticatorData, sha256(clientDataJSON)));
    }

    function _formattedProof(uint256 privateKey, bytes32 challenge, bytes memory formatterData)
        internal
        view
        returns (bytes memory)
    {
        return _formattedProofWithAuthenticatorData(
            privateKey, challenge, formatterData, _authenticatorData(expectedRpIdHash, FLAGS_UP_UV)
        );
    }

    function _formattedProofWithAuthenticatorData(
        uint256 privateKey,
        bytes32 challenge,
        bytes memory formatterData,
        bytes memory authenticatorData
    ) internal pure returns (bytes memory) {
        bytes32 digest = _formattedMessageHash(challenge, formatterData, authenticatorData);
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, digest);
        (uint256 qx, uint256 qy) = vm.publicKeyP256(privateKey);
        return abi.encode(r, s, bytes32(qx), bytes32(qy), authenticatorData);
    }

    function _formattedEntry(bytes memory proof)
        internal
        pure
        returns (IFrameVm.FrameTxSignature memory)
    {
        return _entry(SCHEME_ARBITRARY, address(0), bytes32(0), proof);
    }
}

/// Native P256 is the conformance authorization, so the inherited suite exercises
/// self-payment, external paymasters, and account sponsor-only PAYMENT with scheme 0x02.
contract FrameKernelNativeP256Test is FrameKernelTestBase {
    uint256 private constant OTHER_NATIVE_P256_KEY =
        0x4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef123;
    address private constant K1_SIGNER = address(0xBEEF8141);
    address private constant LEGACY_ACCOUNT = address(0xF8141001);
    address private constant LEGACY_SIGNER = address(0xF8141002);
    address private constant LEGACY_FORMATTER = address(0xBEEF01);

    address internal nativeP256Signer;

    function setUp() public {
        _prepareCredential();
        (uint256 qx, uint256 qy) = vm.publicKeyP256(BOOTSTRAP_P256_KEY);
        nativeP256Signer = _p256Signer(bytes32(qx), bytes32(qy));
        account = address(new FrameKernel(SCHEME_P256, nativeP256Signer, IFormatter(address(0))));
    }

    function accountAuthorizationSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _entry(SCHEME_P256, nativeP256Signer, bytes32(0), "");
    }

    function accountUnauthorizedSignatures()
        internal
        pure
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        (uint256 qx, uint256 qy) = vm.publicKeyP256(OTHER_NATIVE_P256_KEY);
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _entry(SCHEME_P256, _p256Signer(bytes32(qx), bytes32(qy)), bytes32(0), "");
    }

    function test_constructorInstallsOnlyTheSelectedP256Scheme() public view {
        FrameKernel kernel = FrameKernel(payable(account));
        assertTrue(kernel.nativeSigner(SCHEME_P256, nativeP256Signer));
        assertFalse(kernel.nativeSigner(SCHEME_SECP256K1, nativeP256Signer));
        assertEq(address(kernel.formatter(nativeP256Signer)), address(0));
        assertEq(bytes4(keccak256("validate(uint256)")), IFrameAccount.validate.selector);
    }

    function test_sameAddressUnderSecp256k1DoesNotInheritP256Authority() public {
        assertRefusesFrame(
            account,
            _contextFor(
                account, _entry(SCHEME_SECP256K1, nativeP256Signer, bytes32(0), ""), SCOPE_BOTH
            ),
            "native authority must include the protocol scheme"
        );
    }

    function test_nativeP256ExplicitMessageIsRefused() public {
        assertRefusesFrame(
            account,
            _contextFor(
                account,
                _entry(SCHEME_P256, nativeP256Signer, keccak256("explicit"), ""),
                SCOPE_BOTH
            ),
            "explicit digest must not authorize replaceable frames"
        );
    }

    function test_selfCanAddAndRevokeNativeSecp256k1Signer() public {
        FrameKernel kernel = FrameKernel(payable(account));
        vm.expectRevert(FrameKernel.OnlySelf.selector);
        kernel.setNativeSigner(SCHEME_SECP256K1, K1_SIGNER, true);

        vm.prank(account);
        kernel.setNativeSigner(SCHEME_SECP256K1, K1_SIGNER, true);
        assertApprovesFrame(
            account,
            _contextFor(account, _entry(SCHEME_SECP256K1, K1_SIGNER, bytes32(0), ""), SCOPE_BOTH),
            "self-installed K1 signer must authorize"
        );

        vm.prank(account);
        kernel.setNativeSigner(SCHEME_SECP256K1, K1_SIGNER, false);
        assertRefusesFrame(
            account,
            _contextFor(account, _entry(SCHEME_SECP256K1, K1_SIGNER, bytes32(0), ""), SCOPE_BOTH),
            "revoked K1 signer must stop authorizing"
        );
    }

    function test_legacySlotZeroSignerCanMigrateToExactP256AndRevoke() public {
        deployAccount("FrameKernel", LEGACY_ACCOUNT);
        bytes32 legacySlot = keccak256(abi.encode(LEGACY_SIGNER, uint256(0)));
        vm.store(LEGACY_ACCOUNT, legacySlot, bytes32(uint256(1)));
        FrameKernel legacy = FrameKernel(payable(LEGACY_ACCOUNT));
        assertEq(address(legacy.formatter(LEGACY_SIGNER)), address(1));

        assertApprovesFrame(
            LEGACY_ACCOUNT,
            _contextFor(
                LEGACY_ACCOUNT, _entry(SCHEME_SECP256K1, LEGACY_SIGNER, bytes32(0), ""), SCOPE_BOTH
            ),
            "legacy sentinel authorizes canonical native signing"
        );

        vm.prank(LEGACY_ACCOUNT);
        legacy.migrateLegacySigner(SCHEME_P256, LEGACY_SIGNER, true);
        assertEq(address(legacy.formatter(LEGACY_SIGNER)), address(0));
        assertTrue(legacy.nativeSigner(SCHEME_P256, LEGACY_SIGNER));
        assertRefusesFrame(
            LEGACY_ACCOUNT,
            _contextFor(
                LEGACY_ACCOUNT, _entry(SCHEME_SECP256K1, LEGACY_SIGNER, bytes32(0), ""), SCOPE_BOTH
            ),
            "migration must close the cross-scheme path"
        );
    }

    function test_invalidConstructorAndNativeConfigurationAreRefused() public {
        WebAuthnFormatter selectedFormatter = new WebAuthnFormatter();
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        new FrameKernel(SCHEME_ARBITRARY, nativeP256Signer, IFormatter(address(0)));
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        new FrameKernel(SCHEME_P256, nativeP256Signer, selectedFormatter);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        new FrameKernel(SCHEME_P256, address(0), IFormatter(address(0)));

        FrameKernel kernel = FrameKernel(payable(account));
        vm.prank(account);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        kernel.setNativeSigner(3, K1_SIGNER, true);
        vm.prank(account);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        kernel.setNativeSigner(SCHEME_SECP256K1, address(0), true);
    }

    function test_directValidationRequiresVerifyMode() public {
        IFrameVm.FrameTx memory ctx =
            _contextFor(account, _entry(SCHEME_P256, nativeP256Signer, bytes32(0), ""), SCOPE_BOTH);
        ctx.frames[0].mode = MODE_DEFAULT;
        assertRefusesFrame(account, ctx, "DEFAULT frames cannot enter validation");
    }

    function test_formattedAndExecuteAbisCannotBorrowNativeAuthority() public {
        IFrameVm.FrameTx memory ctx =
            _contextFor(account, _entry(SCHEME_P256, nativeP256Signer, bytes32(0), ""), SCOPE_BOTH);
        ctx.frames[0].data = abi.encodeWithSignature("validate(uint256,bytes)", 0, bytes("x"));
        assertRefusesFrame(account, ctx, "formatted path must require ARBITRARY P256 proof");

        ctx.frames[0].data =
            abi.encodeWithSignature("execute(address,uint256,bytes)", address(1), 0, bytes(""));
        assertRefusesFrame(account, ctx, "generic execute must not exist");
    }

    function test_nonSentinelLegacyFormatterIsNotDirectNativeAuthority() public {
        deployAccount("FrameKernel", LEGACY_ACCOUNT);
        bytes32 legacySlot = keccak256(abi.encode(LEGACY_SIGNER, uint256(0)));
        vm.store(LEGACY_ACCOUNT, legacySlot, bytes32(uint256(uint160(LEGACY_FORMATTER))));
        assertRefusesFrame(
            LEGACY_ACCOUNT,
            _contextFor(
                LEGACY_ACCOUNT, _entry(SCHEME_P256, LEGACY_SIGNER, bytes32(0), ""), SCOPE_BOTH
            ),
            "a formatter address is not direct native authority"
        );
    }
}

/// The formatter produces only the WebAuthn message digest. FrameKernel derives the
/// P256 key from the ARBITRARY proof, checks its slot-0 authority, and verifies P256 itself.
contract FrameKernelWebAuthnFormatterTest is FrameKernelTestBase {
    WebAuthnFormatter internal webAuthnFormatter;

    function setUp() public {
        _prepareCredential();
        webAuthnFormatter = new WebAuthnFormatter();
        account = address(new FrameKernel(SCHEME_ARBITRARY, credentialSigner, webAuthnFormatter));
    }

    function _validationCalldata(uint256 signatureIndex)
        internal
        view
        override
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "validate(uint256,bytes)", signatureIndex, _validFormatterData()
        );
    }

    function accountValidationCalldata(uint256 signatureIndex)
        internal
        view
        override
        returns (bytes memory)
    {
        return _validationCalldata(signatureIndex);
    }

    function accountAuthorizationSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _formattedEntry(
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, _validFormatterData())
        );
    }

    function accountUnauthorizedSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _formattedEntry(
            _formattedProof(OTHER_CREDENTIAL_KEY, SUITE_CHALLENGE, _validFormatterData())
        );
    }

    function _contextWith(bytes memory formatterData, bytes memory proof)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        ctx = _contextFor(account, _formattedEntry(proof), SCOPE_BOTH);
        ctx.frames[0].data = abi.encodeWithSignature("validate(uint256,bytes)", 0, formatterData);
    }

    function _assertInvalid(bytes memory formatterData, bytes memory proof, string memory reason)
        internal
    {
        assertRefusesFrame(account, _contextWith(formatterData, proof), reason);
    }

    function test_kernelOwnsNoWebAuthnCredentialOrPolicy() public {
        FrameKernel kernel = FrameKernel(payable(account));
        assertEq(address(kernel.formatter(credentialSigner)), address(webAuthnFormatter));
        assertFalse(kernel.nativeSigner(SCHEME_P256, credentialSigner));
        assertEq(kernel.signerForP256Key(publicKeyX, publicKeyY), credentialSigner);

        (bool getterExists,) = account.staticcall(
            abi.encodeWithSignature("webAuthnCredential(address)", credentialSigner)
        );
        assertFalse(getterExists, "WebAuthn credential state must not exist on FrameKernel");
        (bool setterExists,) = account.call(
            abi.encodeWithSignature(
                "setWebAuthnCredential(bytes32,bytes32,bytes32,string,bool)",
                publicKeyX,
                publicKeyY,
                expectedRpIdHash,
                ORIGIN,
                true
            )
        );
        assertFalse(setterExists, "WebAuthn configuration must not exist on FrameKernel");
    }

    function test_formatterOnlyProducesTheExpectedP256Digest() public view {
        bytes memory formatterData = _validFormatterData();
        bytes memory authenticatorData = _authenticatorData(expectedRpIdHash, FLAGS_UP_UV);
        bytes32 expected = _formattedMessageHash(SUITE_CHALLENGE, formatterData, authenticatorData);
        bytes32 actual =
            webAuthnFormatter.format(SUITE_CHALLENGE, formatterData, authenticatorData, 7);
        assertEq(actual, expected);
    }

    function test_realWebAuthnP256ProofApproves() public {
        bytes memory formatterData = _validFormatterData();
        bytes memory proof = _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, formatterData);
        assertEq(proof.length, 256);
        assertApprovesFrame(
            account,
            _contextWith(formatterData, proof),
            "FrameKernel must verify the P256 proof over the formatter digest"
        );
    }

    function test_authenticatorCounterLivesInTheElidedFormatterProof() public {
        bytes memory formatterData = _validFormatterData();
        bytes memory firstProof = _formattedProofWithAuthenticatorData(
            CREDENTIAL_KEY,
            SUITE_CHALLENGE,
            formatterData,
            _authenticatorDataWithCounter(expectedRpIdHash, FLAGS_UP_UV, 7)
        );
        bytes memory nextProof = _formattedProofWithAuthenticatorData(
            CREDENTIAL_KEY,
            SUITE_CHALLENGE,
            formatterData,
            _authenticatorDataWithCounter(expectedRpIdHash, FLAGS_UP_UV, 8)
        );

        IFrameVm.FrameTx memory first = _contextWith(formatterData, firstProof);
        IFrameVm.FrameTx memory next = _contextWith(formatterData, nextProof);
        assertEq(
            keccak256(first.frames[0].data),
            keccak256(next.frames[0].data),
            "response-time authenticator data must not change signed frame calldata"
        );
        assertApprovesFrame(account, first, "counter 7 proof");
        assertApprovesFrame(account, next, "counter 8 proof");
    }

    function test_wrongChallengeKeyAndTemplateTamperingAreRefused() public {
        bytes memory formatterData = _validFormatterData();
        _assertInvalid(
            formatterData,
            _formattedProof(CREDENTIAL_KEY, bytes32(uint256(0xDEAD)), formatterData),
            "a WebAuthn proof over another challenge"
        );
        _assertInvalid(
            formatterData,
            _formattedProof(OTHER_CREDENTIAL_KEY, SUITE_CHALLENGE, formatterData),
            "an unconfigured P256 key"
        );

        bytes memory proof = _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, formatterData);
        bytes memory changedTemplate =
            _formatterData("https://changed.example", "webauthn.get", false);
        _assertInvalid(changedTemplate, proof, "formatter data is part of the signed digest");
    }

    function test_wrongTypeChallengeMarkerPresenceAndUvAreRefused() public {
        bytes memory wrongType = _formatterData(ORIGIN, "webauthn.create", false);
        _assertInvalid(
            wrongType,
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, wrongType),
            "credential creation is not an authentication assertion"
        );

        bytes memory crossOrigin = _formatterData(ORIGIN, "webauthn.get", true);
        _assertInvalid(
            crossOrigin,
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, crossOrigin),
            "cross-origin assertions are outside this formatter profile"
        );

        bytes memory prefix = bytes('{"type":"webauthn.get","challenge":"');
        bytes memory beforeCrossOrigin = abi.encodePacked('","origin":"', ORIGIN, '",');
        bytes memory topOrigin = abi.encode(
            prefix,
            abi.encodePacked(
                beforeCrossOrigin, '"crossOrigin":false,"topOrigin":"https://top.example"}'
            ),
            uint256(1),
            prefix.length + 43 + beforeCrossOrigin.length
        );
        _assertInvalid(
            topOrigin,
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, topOrigin),
            "top-origin assertions are outside this formatter profile"
        );

        bytes memory noPresence = _formatterData(ORIGIN, "webauthn.get", false);
        _assertInvalid(
            noPresence,
            _formattedProofWithAuthenticatorData(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                noPresence,
                _authenticatorData(expectedRpIdHash, 0x04)
            ),
            "user presence is required"
        );

        bytes memory noUv = _formatterData(ORIGIN, "webauthn.get", false);
        _assertInvalid(
            noUv,
            _formattedProofWithAuthenticatorData(
                CREDENTIAL_KEY, SUITE_CHALLENGE, noUv, _authenticatorData(expectedRpIdHash, 0x01)
            ),
            "the WebAuthn formatter always requires user verification"
        );

        bytes memory malformed = abi.encode(
            bytes('{"type":"webauthn.get","challenge":'),
            bytes('","origin":"https://wallet.example"}'),
            uint256(1),
            uint256(100)
        );
        _assertInvalid(
            malformed,
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, malformed),
            "template must expose one challenge value slot"
        );
    }

    function test_userVerificationCannotBeDisabledByFrameData() public {
        bytes memory upOnly = _formatterData(ORIGIN, "webauthn.get", false);
        bytes memory proof = _formattedProofWithAuthenticatorData(
            CREDENTIAL_KEY, SUITE_CHALLENGE, upOnly, _authenticatorData(expectedRpIdHash, 0x01)
        );
        _assertInvalid(
            upOnly, proof, "frame data cannot weaken the formatter's user-verification policy"
        );

        (bytes memory prefix, bytes memory suffix, uint256 typeIndex,) =
            abi.decode(upOnly, (bytes, bytes, uint256, uint256));
        bytes memory obsoleteCallerPolicy = abi.encode(prefix, suffix, typeIndex, false);
        _assertInvalid(
            obsoleteCallerPolicy,
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, obsoleteCallerPolicy),
            "caller-selected WebAuthn policy is not formatter data"
        );
    }

    function test_tamperedAndHighSP256ProofsAreRefused() public {
        bytes memory formatterData = _validFormatterData();
        (bytes32 r, bytes32 s, bytes32 qx, bytes32 qy, bytes memory authenticatorData) = abi.decode(
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, formatterData),
            (bytes32, bytes32, bytes32, bytes32, bytes)
        );
        _assertInvalid(
            formatterData,
            abi.encode(bytes32(uint256(r) + 1), s, qx, qy, authenticatorData),
            "tampered P256 r"
        );
        _assertInvalid(
            formatterData,
            abi.encode(r, bytes32(P256_N - uint256(s)), qx, qy, authenticatorData),
            "malleable high-s P256 signature"
        );
    }

    function test_malformedWrongLengthAndExplicitMessageProofsAreRefused() public {
        bytes memory formatterData = _validFormatterData();
        _assertInvalid(formatterData, hex"deadbeef", "malformed proof");
        _assertInvalid(
            formatterData,
            bytes.concat(_formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, formatterData), hex"00"),
            "trailing proof byte"
        );

        IFrameVm.FrameTxSignature memory explicit = _entry(
            SCHEME_ARBITRARY,
            address(0),
            keccak256("explicit"),
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, formatterData)
        );
        IFrameVm.FrameTx memory ctx = _contextFor(account, explicit, SCOPE_BOTH);
        ctx.frames[0].data = abi.encodeWithSignature("validate(uint256,bytes)", 0, formatterData);
        assertRefusesFrame(account, ctx, "formatted proof must bind the canonical frame hash");
    }

    function test_nativeP256MetadataCannotMasqueradeAsFormattedProof() public {
        IFrameVm.FrameTx memory ctx =
            _contextFor(account, _entry(SCHEME_P256, credentialSigner, bytes32(0), ""), SCOPE_BOTH);
        ctx.frames[0].data =
            abi.encodeWithSignature("validate(uint256,bytes)", 0, _validFormatterData());
        assertRefusesFrame(account, ctx, "formatted validation requires an introspectable proof");

        ctx.frames[0].data = validationCalldata(0);
        assertRefusesFrame(account, ctx, "formatter authority is not direct native authority");
    }

    function test_onlySelfCanInstallRotateAndRevokeFormatter() public {
        FrameKernel kernel = FrameKernel(payable(account));
        WebAuthnFormatter replacement = new WebAuthnFormatter();

        vm.expectRevert(FrameKernel.OnlySelf.selector);
        kernel.setFormatter(credentialSigner, replacement);

        vm.prank(account);
        kernel.setFormatter(credentialSigner, replacement);
        assertEq(address(kernel.formatter(credentialSigner)), address(replacement));
        assertApprovesFrame(
            account,
            _contextWith(
                _validFormatterData(),
                _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, _validFormatterData())
            ),
            "replacement pure formatter must preserve key authority"
        );

        vm.prank(account);
        kernel.setFormatter(credentialSigner, IFormatter(address(0)));
        _assertInvalid(
            _validFormatterData(),
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, _validFormatterData()),
            "revoked formatter"
        );
    }

    function test_invalidFormatterConfigurationIsRefused() public {
        FrameKernel kernel = FrameKernel(payable(account));
        vm.prank(account);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        kernel.setFormatter(address(0), webAuthnFormatter);
        vm.prank(account);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        kernel.setFormatter(credentialSigner, IFormatter(address(1)));
        vm.prank(account);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        kernel.setFormatter(credentialSigner, IFormatter(address(0xBEEF)));
    }

    function test_untrustedFormatterBehaviorFailsClosed() public {
        _assertBadFormatter(IFormatter(address(new ZeroFormatter())), "zero digest formatter");
        _assertBadFormatter(IFormatter(address(new RevertingFormatter())), "reverting formatter");
        _assertBadFormatter(
            IFormatter(address(new ExtraReturnFormatter())), "non-canonical formatter return"
        );
        _assertBadFormatter(IFormatter(address(new HugeReturnFormatter())), "return-bomb formatter");
        _assertBadFormatter(
            IFormatter(address(new StateWritingFormatter())), "state-writing formatter"
        );
    }

    function _assertBadFormatter(IFormatter badFormatter, string memory reason) private {
        vm.prank(account);
        FrameKernel(payable(account)).setFormatter(credentialSigner, badFormatter);
        _assertInvalid(
            _validFormatterData(),
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, _validFormatterData()),
            reason
        );
    }

    function test_formattedValidationRequiresVerifyMode() public {
        bytes memory formatterData = _validFormatterData();
        IFrameVm.FrameTx memory ctx = _contextWith(
            formatterData, _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, formatterData)
        );
        ctx.frames[0].mode = MODE_DEFAULT;
        assertRefusesFrame(account, ctx, "DEFAULT frames cannot enter formatted validation");
    }

    function test_shortAuthenticatorDataAndMalformedAbiAreRefused() public {
        bytes memory formatterData = _validFormatterData();
        bytes memory shortAuthenticatorData = new bytes(36);
        shortAuthenticatorData[32] = bytes1(FLAGS_UP_UV);
        _assertInvalid(
            formatterData,
            _formattedProofWithAuthenticatorData(
                CREDENTIAL_KEY, SUITE_CHALLENGE, formatterData, shortAuthenticatorData
            ),
            "authenticator data must include the fixed counter"
        );

        bytes memory malformedProof =
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, formatterData);
        assembly ("memory-safe") {
            mstore(add(malformedProof, 0xa0), 0xc0)
        }
        _assertInvalid(formatterData, malformedProof, "non-canonical proof offset");

        bytes memory malformedFormatterData = bytes.concat(formatterData);
        assembly ("memory-safe") {
            mstore(add(malformedFormatterData, 0x20), 0x60)
        }
        _assertInvalid(
            malformedFormatterData,
            _formattedProof(CREDENTIAL_KEY, SUITE_CHALLENGE, formatterData),
            "non-canonical formatter-data offset"
        );
    }
}

contract ZeroFormatter is IFormatter {
    function format(bytes32, bytes calldata, bytes calldata, uint256)
        external
        pure
        returns (bytes32)
    {
        return bytes32(0);
    }
}

contract RevertingFormatter is IFormatter {
    function format(bytes32, bytes calldata, bytes calldata, uint256)
        external
        pure
        returns (bytes32)
    {
        revert("formatter rejected");
    }
}

contract ExtraReturnFormatter {
    function format(bytes32, bytes calldata, bytes calldata, uint256)
        external
        pure
        returns (bytes32, bytes32)
    {
        return (bytes32(uint256(1)), bytes32(uint256(2)));
    }
}

contract HugeReturnFormatter {
    function format(bytes32, bytes calldata, bytes calldata, uint256)
        external
        pure
        returns (bytes32)
    {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 0x4000)
        }
    }
}

contract StateWritingFormatter {
    uint256 private value;

    function format(bytes32, bytes calldata, bytes calldata, uint256) external returns (bytes32) {
        value = 1;
        return bytes32(value);
    }
}
