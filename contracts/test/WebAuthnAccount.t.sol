// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFrameVm} from "./FrameTest.sol";
import {AccountTestSuite} from "./AccountTestSuite.sol";
import {WebAuthnAccount} from "../src/accounts/WebAuthnAccount.sol";
import {Base64Url} from "../src/crypto/Base64Url.sol";

/// WebAuthn account tests. Unlike protocol P256 fixture entries, every positive
/// assertion here contains a real P256 signature checked by precompile 0x100.
contract WebAuthnAccountTest is AccountTestSuite {
    uint8 private constant SCHEME_ARBITRARY = 0;
    uint8 private constant SCHEME_P256 = 2;
    uint8 private constant FLAGS_UP_UV = 0x05;
    uint256 private constant CREDENTIAL_KEY =
        0x123456789abcdef123456789abcdef123456789abcdef123456789abcdef1234;
    uint256 private constant OTHER_CREDENTIAL_KEY =
        0x23456789abcdef123456789abcdef123456789abcdef123456789abcdef12345;
    uint256 private constant P256_N =
        0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    bytes32 private constant SUITE_CHALLENGE = bytes32(uint256(0x8141));
    string private constant RP_ID = "wallet.example";
    string private constant ORIGIN = "https://wallet.example";

    address internal account;
    bytes32 internal publicKeyX;
    bytes32 internal publicKeyY;
    bytes32 internal expectedRpIdHash;
    bytes32 internal expectedOriginHash;

    function setUp() public {
        (uint256 qx, uint256 qy) = vm.publicKeyP256(CREDENTIAL_KEY);
        publicKeyX = bytes32(qx);
        publicKeyY = bytes32(qy);
        expectedRpIdHash = sha256(bytes(RP_ID));
        expectedOriginHash = keccak256(bytes(ORIGIN));
        account = address(
            new WebAuthnAccount(publicKeyX, publicKeyY, expectedRpIdHash, expectedOriginHash, true)
        );
    }

    function accountUnderTest() internal view override returns (address) {
        return account;
    }

    function accountSuiteSigHash() internal pure override returns (bytes32) {
        return SUITE_CHALLENGE;
    }

    function accountAuthorizationSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _entry(
            SCHEME_ARBITRARY,
            bytes32(0),
            _assertion(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                false
            )
        );
    }

    function accountUnauthorizedSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        // A completely valid assertion from another credential proves that the
        // shifted-index negative tests exercise key policy, not only scheme filtering.
        signatures[0] = _entry(
            SCHEME_ARBITRARY,
            bytes32(0),
            _assertion(
                OTHER_CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                false
            )
        );
    }

    function _entry(uint8 scheme, bytes32 msgHash, bytes memory witness)
        internal
        pure
        returns (IFrameVm.FrameTxSignature memory)
    {
        return IFrameVm.FrameTxSignature({
            scheme: scheme, signer: address(0), msgHash: msgHash, signature: witness
        });
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

    function _assertion(
        uint256 privateKey,
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
        return abi.encode(r, s, authenticatorData, clientData);
    }

    function _validAssertion() internal view returns (bytes memory) {
        return _assertion(
            CREDENTIAL_KEY,
            SUITE_CHALLENGE,
            expectedRpIdHash,
            FLAGS_UP_UV,
            ORIGIN,
            "webauthn.get",
            false
        );
    }

    function _context(IFrameVm.FrameTxSignature memory signature, uint256[] memory indices)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        ctx = verifyContext(account, SCOPE_BOTH, SUITE_CHALLENGE);
        ctx.frames[0].data = validationCalldata(indices);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = signature;
    }

    function _assertInvalid(bytes memory witness, string memory reason) internal {
        assertRefusesFrame(
            account, _context(_entry(SCHEME_ARBITRARY, bytes32(0), witness), selected(0)), reason
        );
    }

    function test_realWebAuthnAssertionApproves() public {
        assertApprovesFrame(
            account,
            _context(_entry(SCHEME_ARBITRARY, bytes32(0), _validAssertion()), selected(0)),
            "a real assertion from the configured credential must approve"
        );
    }

    function test_base64UrlChallengeEncodingIsCanonicalAndUnpadded() public pure {
        assertEq(
            string(Base64Url.encode32(SUITE_CHALLENGE)),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgUE"
        );
        assertEq(
            string(
                Base64Url.encode32(
                    0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
                )
            ),
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        );
        assertEq(
            string(
                Base64Url.encode32(
                    0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
                )
            ),
            "__________________________________________8"
        );
    }

    function test_nativeP256EntryCannotMasqueradeAsWebAuthn() public {
        assertRefusesFrame(
            account,
            _context(_entry(SCHEME_P256, bytes32(0), ""), selected(0)),
            "resolved P256 metadata is not a WebAuthn assertion"
        );
    }

    function test_explicitMessageArbitraryEntryIsRefused() public {
        assertRefusesFrame(
            account,
            _context(
                _entry(SCHEME_ARBITRARY, keccak256("explicit"), _validAssertion()), selected(0)
            ),
            "the witness must be elided from and challenged by the canonical signature hash"
        );
    }

    function test_wrongChallengeIsRefused() public {
        _assertInvalid(
            _assertion(
                CREDENTIAL_KEY,
                bytes32(uint256(0xdead)),
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "the WebAuthn challenge must equal TXPARAM signature hash"
        );
    }

    function test_wrongTypeIsRefused() public {
        _assertInvalid(
            _assertion(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.create",
                false
            ),
            "credential creation assertions must not authorize execution"
        );
    }

    function test_wrongOriginIsRefused() public {
        _assertInvalid(
            _assertion(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                "https://evil.example",
                "webauthn.get",
                false
            ),
            "the exact relying-party origin must match"
        );
    }

    function test_crossOriginAssertionIsRefused() public {
        _assertInvalid(
            _assertion(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                true
            ),
            "this profile accepts only crossOrigin false"
        );
    }

    function test_wrongRpIdHashIsRefused() public {
        _assertInvalid(
            _assertion(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                sha256("evil.example"),
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "authenticator data must bind the configured RP ID"
        );
    }

    function test_userPresenceIsRequired() public {
        _assertInvalid(
            _assertion(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                0x04,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "UP must be set"
        );
    }

    function test_configuredUserVerificationIsRequired() public {
        _assertInvalid(
            _assertion(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                0x01,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "UV must be set for this account"
        );
    }

    function test_backupStateRequiresBackupEligibility() public {
        _assertInvalid(
            _assertion(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                0x15,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "BS without BE is structurally invalid"
        );
    }

    function test_backupEligibleBackedUpPasskeyIsAccepted() public {
        bytes memory assertion = _assertion(
            CREDENTIAL_KEY, SUITE_CHALLENGE, expectedRpIdHash, 0x1d, ORIGIN, "webauthn.get", false
        );
        assertApprovesFrame(
            account,
            _context(_entry(SCHEME_ARBITRARY, bytes32(0), assertion), selected(0)),
            "BE and BS are valid assertion flags"
        );
    }

    function test_reservedAndExtensionFlagsAreRefused() public {
        _assertInvalid(
            _assertion(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                0x07,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "reserved flags must be zero"
        );
        _assertInvalid(
            _assertion(
                CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                0x85,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "the initial 37-byte profile does not accept extensions"
        );
    }

    function test_wrongCredentialSignatureIsRefused() public {
        _assertInvalid(
            _assertion(
                OTHER_CREDENTIAL_KEY,
                SUITE_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                false
            ),
            "only the configured public key may authorize"
        );
    }

    function test_tamperedSignatureIsRefused() public {
        (bytes32 r, bytes32 s, bytes memory authData, bytes memory clientData) =
            abi.decode(_validAssertion(), (bytes32, bytes32, bytes, bytes));
        r = bytes32(uint256(r) + 1);
        _assertInvalid(abi.encode(r, s, authData, clientData), "invalid P256 signature");
    }

    function test_highSAlternativeIsRefused() public {
        (bytes32 r, bytes32 s, bytes memory authData, bytes memory clientData) =
            abi.decode(_validAssertion(), (bytes32, bytes32, bytes, bytes));
        s = bytes32(P256_N - uint256(s));
        _assertInvalid(abi.encode(r, s, authData, clientData), "high-s witness is malleable");
    }

    function test_nonCanonicalAbiAndOversizedWitnessesAreRefused() public {
        _assertInvalid(new bytes(255), "truncated witness head");
        _assertInvalid(bytes.concat(_validAssertion(), hex"00"), "trailing witness bytes");

        bytes memory nonZeroPadding = _validAssertion();
        assembly ("memory-safe") {
            // First padding byte after the canonical 37-byte authenticator data.
            mstore8(add(nonZeroPadding, 0xe5), 1)
        }
        _assertInvalid(nonZeroPadding, "non-zero ABI padding");
        _assertInvalid(new bytes(2_049), "witness above the 2 KiB bound");
    }

    function test_forgedAbiOffsetsAndLengthsAreRefused() public {
        bytes memory badAuthenticatorOffset = _validAssertion();
        assembly ("memory-safe") {
            mstore(add(badAuthenticatorOffset, 0x60), 0xa0)
        }
        _assertInvalid(badAuthenticatorOffset, "shifted authenticator-data offset");

        bytes memory overlappingTails = _validAssertion();
        assembly ("memory-safe") {
            mstore(add(overlappingTails, 0x80), 0x80)
        }
        _assertInvalid(overlappingTails, "overlapping dynamic tails");

        bytes memory forgedClientLength = _validAssertion();
        assembly ("memory-safe") {
            mstore(add(forgedClientLength, 0x100), 0)
        }
        _assertInvalid(forgedClientLength, "forged client-data length");
    }

    function test_authenticatorDataMustBeExactly37Bytes() public {
        bytes memory clientData = _clientData(SUITE_CHALLENGE, ORIGIN, "webauthn.get", false);
        bytes memory authData =
            bytes.concat(_authenticatorData(expectedRpIdHash, FLAGS_UP_UV), hex"00");
        bytes32 digest = sha256(abi.encodePacked(authData, sha256(clientData)));
        (bytes32 r, bytes32 s) = vm.signP256(CREDENTIAL_KEY, digest);
        _assertInvalid(abi.encode(r, s, authData, clientData), "authenticator data length");
    }

    function test_exactlyOneSignatureMustBeSelected() public {
        IFrameVm.FrameTxSignature memory entry =
            _entry(SCHEME_ARBITRARY, bytes32(0), _validAssertion());
        assertRefusesFrame(
            account,
            _context(entry, selected(0, 0)),
            "duplicate assertion routing must not be accepted"
        );
    }

    function test_userVerificationCanBeConfiguredOptional() public {
        address relaxedAccount = address(
            new WebAuthnAccount(publicKeyX, publicKeyY, expectedRpIdHash, expectedOriginHash, false)
        );
        bytes memory witness = _assertion(
            CREDENTIAL_KEY, SUITE_CHALLENGE, expectedRpIdHash, 0x01, ORIGIN, "webauthn.get", false
        );
        IFrameVm.FrameTx memory ctx = verifyContext(relaxedAccount, SCOPE_BOTH, SUITE_CHALLENGE);
        ctx.frames[0].data = validationCalldata(selected(0));
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = _entry(SCHEME_ARBITRARY, bytes32(0), witness);
        assertApprovesFrame(
            relaxedAccount, ctx, "UP alone is valid when the credential policy does not require UV"
        );
    }

    function test_invalidConstructorConfigurationIsRefused() public {
        vm.expectRevert(WebAuthnAccount.InvalidConfiguration.selector);
        new WebAuthnAccount(bytes32(0), bytes32(0), expectedRpIdHash, expectedOriginHash, true);

        vm.expectRevert(WebAuthnAccount.InvalidConfiguration.selector);
        new WebAuthnAccount(publicKeyX, publicKeyY, bytes32(0), expectedOriginHash, true);

        vm.expectRevert(WebAuthnAccount.InvalidConfiguration.selector);
        new WebAuthnAccount(publicKeyX, publicKeyY, expectedRpIdHash, bytes32(0), true);
    }
}
