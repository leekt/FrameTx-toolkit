// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccountTestSuite} from "./AccountTestSuite.sol";
import {IFrameVm} from "./FrameTest.sol";
import {Base64Url} from "../src/crypto/Base64Url.sol";
import {FrameKernel} from "../src/accounts/FrameKernel.sol";
import {IFrameAccount} from "../src/accounts/IFrameAccount.sol";

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
    bytes32 internal expectedOriginHash;

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
        expectedOriginHash = keccak256(bytes(ORIGIN));
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

    function _contextFor(address subject, IFrameVm.FrameTxSignature memory signature, uint64 scope)
        internal
        pure
        returns (IFrameVm.FrameTx memory ctx)
    {
        ctx = verifyContext(subject, scope, SUITE_CHALLENGE);
        ctx.frames[0].data = validationCalldata(0);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = signature;
    }

    function _clientData(
        bytes32 challenge,
        string memory origin,
        string memory assertionType,
        bool crossOrigin
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            '{"type":"',
            assertionType,
            '","challenge":"',
            Base64Url.encode32(challenge),
            '","origin":"',
            origin,
            '","crossOrigin":',
            crossOrigin ? "true" : "false",
            "}"
        );
    }

    function _authenticatorData(bytes32 rpHash, uint8 flags) internal pure returns (bytes memory) {
        return abi.encodePacked(rpHash, bytes1(flags), bytes4(0));
    }

    function _compactWitness(
        uint256 privateKey,
        address claimedCredential,
        bytes32 challenge,
        bytes32 rpHash,
        uint8 flags,
        string memory origin,
        string memory assertionType,
        bool crossOrigin
    ) internal pure returns (bytes memory) {
        bytes memory authenticatorData = _authenticatorData(rpHash, flags);
        bytes memory clientData = _clientData(challenge, origin, assertionType, crossOrigin);
        bytes32 digest = sha256(abi.encodePacked(authenticatorData, sha256(clientData)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, digest);
        return abi.encode(claimedCredential, r, s, authenticatorData);
    }

    function _validCompactWitness() internal view returns (bytes memory) {
        return _compactWitness(
            CREDENTIAL_KEY,
            credentialSigner,
            SUITE_CHALLENGE,
            expectedRpIdHash,
            FLAGS_UP_UV,
            ORIGIN,
            "webauthn.get",
            false
        );
    }

    function _webAuthnEntry(bytes memory witness)
        internal
        pure
        returns (IFrameVm.FrameTxSignature memory)
    {
        return _entry(SCHEME_ARBITRARY, address(0), bytes32(0), witness);
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
        account = address(new FrameKernel(SCHEME_P256, nativeP256Signer));
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
        assertEq(FrameKernel.validate.selector, IFrameAccount.validate.selector);
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
        assertEq(
            address(legacy.formatter(LEGACY_SIGNER)),
            address(1),
            "old formatter getter and slot must survive"
        );

        assertApprovesFrame(
            LEGACY_ACCOUNT,
            _contextFor(
                LEGACY_ACCOUNT, _entry(SCHEME_SECP256K1, LEGACY_SIGNER, bytes32(0), ""), SCOPE_BOTH
            ),
            "legacy native sentinel authorizes canonical K1"
        );
        assertApprovesFrame(
            LEGACY_ACCOUNT,
            _contextFor(
                LEGACY_ACCOUNT, _entry(SCHEME_P256, LEGACY_SIGNER, bytes32(0), ""), SCOPE_BOTH
            ),
            "legacy native sentinel preserves the old cross-native-scheme policy"
        );

        vm.prank(LEGACY_ACCOUNT);
        legacy.migrateLegacySigner(SCHEME_P256, LEGACY_SIGNER, true);
        assertEq(
            address(legacy.formatter(LEGACY_SIGNER)), address(0), "migration must clear slot zero"
        );
        assertTrue(legacy.nativeSigner(SCHEME_P256, LEGACY_SIGNER));
        assertRefusesFrame(
            LEGACY_ACCOUNT,
            _contextFor(
                LEGACY_ACCOUNT, _entry(SCHEME_SECP256K1, LEGACY_SIGNER, bytes32(0), ""), SCOPE_BOTH
            ),
            "migration must close the cross-scheme path"
        );
        assertApprovesFrame(
            LEGACY_ACCOUNT,
            _contextFor(
                LEGACY_ACCOUNT, _entry(SCHEME_P256, LEGACY_SIGNER, bytes32(0), ""), SCOPE_BOTH
            ),
            "migration must preserve the selected scheme"
        );

        vm.prank(LEGACY_ACCOUNT);
        legacy.setNativeSigner(SCHEME_P256, LEGACY_SIGNER, false);
        assertRefusesFrame(
            LEGACY_ACCOUNT,
            _contextFor(
                LEGACY_ACCOUNT, _entry(SCHEME_P256, LEGACY_SIGNER, bytes32(0), ""), SCOPE_BOTH
            ),
            "migrated legacy authority must be revocable"
        );
    }

    function test_nonSentinelLegacyFormatterNeverBecomesNativeAuthority() public {
        deployAccount("FrameKernel", LEGACY_ACCOUNT);
        bytes32 legacySlot = keccak256(abi.encode(LEGACY_SIGNER, uint256(0)));
        vm.store(LEGACY_ACCOUNT, legacySlot, bytes32(uint256(uint160(LEGACY_FORMATTER))));
        FrameKernel legacy = FrameKernel(payable(LEGACY_ACCOUNT));
        assertEq(address(legacy.formatter(LEGACY_SIGNER)), LEGACY_FORMATTER);

        assertRefusesFrame(
            LEGACY_ACCOUNT,
            _contextFor(
                LEGACY_ACCOUNT, _entry(SCHEME_SECP256K1, LEGACY_SIGNER, bytes32(0), ""), SCOPE_BOTH
            ),
            "legacy formatter address must not become K1 authority"
        );
        assertRefusesFrame(
            LEGACY_ACCOUNT,
            _contextFor(
                LEGACY_ACCOUNT, _entry(SCHEME_P256, LEGACY_SIGNER, bytes32(0), ""), SCOPE_BOTH
            ),
            "legacy formatter address must not become P256 authority"
        );
    }

    function test_invalidConstructorAndNativeConfigurationAreRefused() public {
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        new FrameKernel(SCHEME_ARBITRARY, nativeP256Signer);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        new FrameKernel(SCHEME_P256, address(0));

        FrameKernel kernel = FrameKernel(payable(account));
        vm.prank(account);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        kernel.setNativeSigner(3, K1_SIGNER, true);
        vm.prank(account);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        kernel.setNativeSigner(SCHEME_SECP256K1, address(0), true);
    }

    function test_reservedSignatureSchemeIsRefused() public {
        assertRefusesFrame(
            account,
            _contextFor(account, _entry(3, address(0), bytes32(0), ""), SCOPE_BOTH),
            "reserved signature schemes must fail closed"
        );
    }

    function test_removedTwoArgumentAndExecuteAbisAreRefused() public {
        IFrameVm.FrameTx memory ctx =
            _contextFor(account, _entry(SCHEME_P256, nativeP256Signer, bytes32(0), ""), SCOPE_BOTH);
        ctx.frames[0].data = abi.encodeWithSignature("validate(uint256,bytes)", 0, bytes(""));
        assertRefusesFrame(account, ctx, "old formatter calldata ABI must stay removed");

        ctx.frames[0].data =
            abi.encodeWithSignature("execute(address,uint256,bytes)", address(1), 0, bytes(""));
        assertRefusesFrame(account, ctx, "generic execute must not exist");
    }
}

/// WebAuthn uses a scheme-0 envelope entry, but every positive assertion below is
/// an actual P256 signature checked by P256VERIFY through WebAuthnVerifier.
contract FrameKernelWebAuthnTest is FrameKernelTestBase {
    address internal bootstrapSigner;

    function setUp() public {
        _prepareCredential();
        (uint256 qx, uint256 qy) = vm.publicKeyP256(BOOTSTRAP_P256_KEY);
        bootstrapSigner = _p256Signer(bytes32(qx), bytes32(qy));
        account = address(new FrameKernel(SCHEME_P256, bootstrapSigner));
        vm.prank(account);
        FrameKernel(payable(account))
            .setWebAuthnCredential(publicKeyX, publicKeyY, expectedRpIdHash, ORIGIN, true);
    }

    function accountAuthorizationSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _webAuthnEntry(_validCompactWitness());
    }

    function accountUnauthorizedSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _webAuthnEntry(
            _compactWitness(
                OTHER_CREDENTIAL_KEY,
                credentialSigner,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                false
            )
        );
    }

    function _assertInvalid(bytes memory witness, string memory reason) internal {
        assertRefusesFrame(
            account, _contextFor(account, _webAuthnEntry(witness), SCOPE_BOTH), reason
        );
    }

    function test_realCompactWebAuthnP256AssertionApproves() public {
        bytes memory witness = _validCompactWitness();
        assertEq(witness.length, FrameKernel(payable(account)).WEB_AUTHN_WITNESS_LENGTH());
        assertApprovesFrame(
            account,
            _contextFor(account, _webAuthnEntry(witness), SCOPE_BOTH),
            "compact WebAuthn witness must verify its real P256 signature"
        );
    }

    function test_credentialConfigurationIsStoredAndDerivedFromP256Key() public view {
        (
            bytes32 qx,
            bytes32 qy,
            bytes32 rpIdHash,
            bytes32 originHash,
            string memory origin,
            bool requireUserVerification,
            bool enabled
        ) = FrameKernel(payable(account)).webAuthnCredential(credentialSigner);
        assertEq(qx, publicKeyX);
        assertEq(qy, publicKeyY);
        assertEq(rpIdHash, expectedRpIdHash);
        assertEq(originHash, expectedOriginHash);
        assertEq(origin, ORIGIN);
        assertTrue(requireUserVerification);
        assertTrue(enabled);
        assertEq(
            FrameKernel(payable(account)).signerForP256Key(publicKeyX, publicKeyY), credentialSigner
        );
    }

    function test_malformedEmptyMessageWitnessFailsClosed() public {
        _assertInvalid(hex"deadbeef", "zero msg must not make malformed formatter data pass");
    }

    function test_explicitMessageWebAuthnEntryIsRefused() public {
        IFrameVm.FrameTxSignature memory signature =
            _entry(SCHEME_ARBITRARY, address(0), keccak256("explicit"), _validCompactWitness());
        assertRefusesFrame(
            account,
            _contextFor(account, signature, SCOPE_BOTH),
            "WebAuthn must bind the canonical frame hash"
        );
    }

    function test_nativeP256MetadataCannotMasqueradeAsConfiguredWebAuthn() public {
        assertRefusesFrame(
            account,
            _contextFor(account, _entry(SCHEME_P256, credentialSigner, bytes32(0), ""), SCOPE_BOTH),
            "a passkey credential is not automatically a native P256 authority"
        );
    }

    function test_wrongChallengeOriginTypeAndCrossOriginAreRefused() public {
        _assertInvalid(
            _compactWitness(
                CREDENTIAL_KEY,
                credentialSigner,
                bytes32(uint256(0xDEAD)),
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "signature over another challenge"
        );
        _assertInvalid(
            _compactWitness(
                CREDENTIAL_KEY,
                credentialSigner,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                "https://evil.example",
                "webauthn.get",
                false
            ),
            "signature over another origin"
        );
        _assertInvalid(
            _compactWitness(
                CREDENTIAL_KEY,
                credentialSigner,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.create",
                false
            ),
            "credential creation type"
        );
        _assertInvalid(
            _compactWitness(
                CREDENTIAL_KEY,
                credentialSigner,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                true
            ),
            "cross-origin assertion"
        );
    }

    function test_wrongRpIdUserPresenceAndUserVerificationAreRefused() public {
        _assertInvalid(
            _compactWitness(
                CREDENTIAL_KEY,
                credentialSigner,
                SUITE_CHALLENGE,
                sha256("evil.example"),
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "wrong RP ID hash"
        );
        _assertInvalid(
            _compactWitness(
                CREDENTIAL_KEY,
                credentialSigner,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                0x04,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "missing user presence"
        );
        _assertInvalid(
            _compactWitness(
                CREDENTIAL_KEY,
                credentialSigner,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                0x01,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "missing configured user verification"
        );
    }

    function test_wrongCredentialTamperingAndHighSAreRefused() public {
        (uint256 otherX, uint256 otherY) = vm.publicKeyP256(OTHER_CREDENTIAL_KEY);
        address otherSigner = _p256Signer(bytes32(otherX), bytes32(otherY));
        _assertInvalid(
            _compactWitness(
                OTHER_CREDENTIAL_KEY,
                otherSigner,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "unconfigured credential"
        );

        (address signer, bytes32 r, bytes32 s, bytes memory authData) =
            abi.decode(_validCompactWitness(), (address, bytes32, bytes32, bytes));
        _assertInvalid(abi.encode(signer, bytes32(uint256(r) + 1), s, authData), "tampered P256 r");
        _assertInvalid(
            abi.encode(signer, r, bytes32(P256_N - uint256(s)), authData),
            "malleable high-s P256 signature"
        );
    }

    function test_nonCanonicalAndWrongLengthWitnessesAreRefused() public {
        _assertInvalid(bytes.concat(_validCompactWitness(), hex"00"), "trailing witness byte");

        bytes memory nonZeroPadding = _validCompactWitness();
        nonZeroPadding[197] = bytes1(uint8(1));
        _assertInvalid(nonZeroPadding, "non-zero dynamic-byte padding");

        (address signer, bytes32 r, bytes32 s,) =
            abi.decode(_validCompactWitness(), (address, bytes32, bytes32, bytes));
        _assertInvalid(
            abi.encode(
                signer,
                r,
                s,
                bytes.concat(_authenticatorData(expectedRpIdHash, FLAGS_UP_UV), hex"00")
            ),
            "authenticator data outside the 37-byte profile"
        );
    }

    function test_onlySelfCanConfigureAndRevokeWebAuthnCredential() public {
        FrameKernel kernel = FrameKernel(payable(account));
        vm.expectRevert(FrameKernel.OnlySelf.selector);
        kernel.removeWebAuthnCredential(credentialSigner);

        vm.prank(account);
        kernel.removeWebAuthnCredential(credentialSigner);
        (,,,,,, bool enabled) = kernel.webAuthnCredential(credentialSigner);
        assertFalse(enabled);
        _assertInvalid(_validCompactWitness(), "removed credential");
    }

    function test_userVerificationCanBeConfiguredOptional() public {
        bytes memory upOnlyWitness = _compactWitness(
            CREDENTIAL_KEY,
            credentialSigner,
            SUITE_CHALLENGE,
            expectedRpIdHash,
            0x01,
            ORIGIN,
            "webauthn.get",
            false
        );
        _assertInvalid(upOnlyWitness, "UV is initially required");

        vm.prank(account);
        FrameKernel(payable(account))
            .setWebAuthnCredential(publicKeyX, publicKeyY, expectedRpIdHash, ORIGIN, false);
        assertApprovesFrame(
            account,
            _contextFor(account, _webAuthnEntry(upOnlyWitness), SCOPE_BOTH),
            "UP alone is enough after self configures optional UV"
        );
    }

    function test_invalidWebAuthnConfigurationIsRefused() public {
        FrameKernel kernel = FrameKernel(payable(account));
        vm.expectRevert(FrameKernel.OnlySelf.selector);
        kernel.setWebAuthnCredential(publicKeyX, publicKeyY, expectedRpIdHash, ORIGIN, true);

        vm.startPrank(account);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        kernel.setWebAuthnCredential(bytes32(0), bytes32(0), expectedRpIdHash, ORIGIN, true);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        kernel.setWebAuthnCredential(publicKeyX, publicKeyY, bytes32(0), ORIGIN, true);
        vm.expectRevert(FrameKernel.InvalidConfiguration.selector);
        kernel.setWebAuthnCredential(publicKeyX, publicKeyY, expectedRpIdHash, "", true);
        vm.stopPrank();
    }
}
