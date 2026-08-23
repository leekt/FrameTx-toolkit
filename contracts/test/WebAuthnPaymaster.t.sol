// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFrameVm} from "./FrameTest.sol";
import {PaymasterTestSuite} from "./PaymasterTestSuite.sol";
import {WebAuthnPaymaster} from "../src/accounts/WebAuthnPaymaster.sol";
import {Base64Url} from "../src/crypto/Base64Url.sol";

/// WebAuthn paymaster tests. Inheriting PaymasterTestSuite proves sponsorship
/// across the toolkit account matrix; focused cases pin assertion and cost policy.
contract WebAuthnPaymasterTest is PaymasterTestSuite {
    uint8 private constant SCHEME_ARBITRARY = 0;
    uint8 private constant SCHEME_P256 = 2;
    uint8 private constant FLAGS_UP_UV = 0x05;
    uint256 private constant CREDENTIAL_KEY =
        0x3456789abcdef123456789abcdef123456789abcdef123456789abcdef123456;
    uint256 private constant OTHER_CREDENTIAL_KEY =
        0x456789abcdef123456789abcdef123456789abcdef123456789abcdef1234567;
    uint256 private constant MAX_SPONSORED_COST = 1 ether;
    bytes32 private constant PAYMASTER_CHALLENGE = bytes32(uint256(0xf00d));
    address private constant SENDER_ACCOUNT = address(0xA770);
    string private constant RP_ID = "sponsor.example";
    string private constant ORIGIN = "https://sponsor.example";

    address internal paymaster;
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
        paymaster = address(
            new WebAuthnPaymaster(
                publicKeyX,
                publicKeyY,
                expectedRpIdHash,
                expectedOriginHash,
                true,
                MAX_SPONSORED_COST
            )
        );
        vm.deal(paymaster, 10 ether);

        WebAuthnPaymaster subject = WebAuthnPaymaster(payable(paymaster));
        assertEq(subject.owner(), address(this), "immutable owner");
        assertEq(subject.publicKeyX(), publicKeyX, "immutable qx");
        assertEq(subject.publicKeyY(), publicKeyY, "immutable qy");
        assertEq(subject.rpIdHash(), expectedRpIdHash, "immutable RP ID hash");
        assertEq(subject.originHash(), expectedOriginHash, "immutable origin hash");
        assertTrue(subject.requireUserVerification(), "immutable UV policy");
        assertEq(subject.maxSponsoredCost(), MAX_SPONSORED_COST, "immutable cost cap");
    }

    function _paymasterUnderTest() internal view override returns (address) {
        return paymaster;
    }

    function _paymasterTestSignature()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature memory signature)
    {
        signature = _entry(
            SCHEME_ARBITRARY,
            bytes32(0),
            _assertion(
                CREDENTIAL_KEY,
                PAYMASTER_CHALLENGE,
                expectedRpIdHash,
                FLAGS_UP_UV,
                ORIGIN,
                "webauthn.get",
                false
            )
        );
    }

    function _paymasterTestCall(uint256 signatureIndex)
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encodeWithSelector(WebAuthnPaymaster.sponsorTransaction.selector, signatureIndex);
    }

    function _paymasterTestMaxCost() internal pure override returns (uint256) {
        return 0.5 ether;
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

    function _assertion(
        uint256 privateKey,
        bytes32 challenge,
        bytes32 rpHash,
        uint8 flags,
        string memory origin,
        string memory assertionType,
        bool crossOrigin
    ) internal pure returns (bytes memory) {
        bytes memory authenticatorData = abi.encodePacked(rpHash, bytes1(flags), bytes4(0));
        bytes memory clientData = _clientData(challenge, origin, assertionType, crossOrigin);
        bytes32 digest = sha256(abi.encodePacked(authenticatorData, sha256(clientData)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, digest);
        return abi.encode(r, s, authenticatorData, clientData);
    }

    function _validAssertion() internal view returns (bytes memory) {
        return _assertion(
            CREDENTIAL_KEY,
            PAYMASTER_CHALLENGE,
            expectedRpIdHash,
            FLAGS_UP_UV,
            ORIGIN,
            "webauthn.get",
            false
        );
    }

    function _payContext(
        IFrameVm.FrameTxSignature memory signature,
        uint256 signatureIndex,
        uint256 maxCost,
        uint64 scope
    ) internal view returns (IFrameVm.FrameTx memory ctx) {
        ctx = verifyContext(SENDER_ACCOUNT, scope, PAYMASTER_CHALLENGE);
        ctx.sender = SENDER_ACCOUNT;
        ctx.frameIndex = 1;
        ctx.frames = new IFrameVm.FrameTxFrame[](2);
        ctx.frames[0] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(SCOPE_EXECUTION),
            target: SENDER_ACCOUNT,
            gasLimit: 100_000,
            stateGasLimit: 0,
            value: 0,
            data: "",
            status: 1,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        ctx.frames[1] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(scope),
            target: paymaster,
            gasLimit: 250_000,
            stateGasLimit: 0,
            value: 0,
            data: abi.encodeWithSelector(
                WebAuthnPaymaster.sponsorTransaction.selector, signatureIndex
            ),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = signature;
        ctx.maxCost = maxCost;
        ctx.approvableScopes = scope;
    }

    function _assertInvalid(
        IFrameVm.FrameTxSignature memory signature,
        uint256 signatureIndex,
        uint256 maxCost,
        string memory reason
    ) internal {
        assertRefusesFrame(
            paymaster, _payContext(signature, signatureIndex, maxCost, SCOPE_PAYMENT), reason
        );
    }

    function test_realWebAuthnAssertionApprovesPayment() public {
        IFrameVm.FrameTx memory ctx = _payContext(
            _entry(SCHEME_ARBITRARY, bytes32(0), _validAssertion()), 0, 0.5 ether, SCOPE_PAYMENT
        );
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(paymaster, ctx, "success must reach APPROVE(PAYMENT)");
        ctx.approvableScopes = SCOPE_PAYMENT;
        assertApprovesFrame(paymaster, ctx, "a real sponsor assertion must approve payment");
    }

    function test_nativeP256EntryCannotMasqueradeAsWebAuthn() public {
        _assertInvalid(
            _entry(SCHEME_P256, bytes32(0), ""),
            0,
            0.5 ether,
            "native P256 metadata is not a WebAuthn assertion"
        );
    }

    function test_nativeMLDSAEntryCannotMasqueradeAsWebAuthn() public {
        _assertInvalid(
            mldsaSig(address(0xA44)),
            0,
            0.5 ether,
            "native ML-DSA-44 metadata is not a WebAuthn assertion"
        );
    }

    function test_explicitMessageArbitraryEntryIsRefused() public {
        _assertInvalid(
            _entry(SCHEME_ARBITRARY, keccak256("explicit"), _validAssertion()),
            0,
            0.5 ether,
            "the assertion must challenge the canonical transaction"
        );
    }

    function test_wrongChallengeIsRefused() public {
        bytes memory witness = _assertion(
            CREDENTIAL_KEY,
            bytes32(uint256(0xbeef)),
            expectedRpIdHash,
            FLAGS_UP_UV,
            ORIGIN,
            "webauthn.get",
            false
        );
        _assertInvalid(
            _entry(SCHEME_ARBITRARY, bytes32(0), witness), 0, 0.5 ether, "challenge mismatch"
        );
    }

    function test_wrongOriginIsRefused() public {
        bytes memory witness = _assertion(
            CREDENTIAL_KEY,
            PAYMASTER_CHALLENGE,
            expectedRpIdHash,
            FLAGS_UP_UV,
            "https://evil.example",
            "webauthn.get",
            false
        );
        _assertInvalid(
            _entry(SCHEME_ARBITRARY, bytes32(0), witness), 0, 0.5 ether, "origin mismatch"
        );
    }

    function test_wrongCredentialIsRefused() public {
        bytes memory witness = _assertion(
            OTHER_CREDENTIAL_KEY,
            PAYMASTER_CHALLENGE,
            expectedRpIdHash,
            FLAGS_UP_UV,
            ORIGIN,
            "webauthn.get",
            false
        );
        _assertInvalid(
            _entry(SCHEME_ARBITRARY, bytes32(0), witness), 0, 0.5 ether, "credential mismatch"
        );
    }

    function test_missingUserVerificationIsRefused() public {
        bytes memory witness = _assertion(
            CREDENTIAL_KEY,
            PAYMASTER_CHALLENGE,
            expectedRpIdHash,
            0x01,
            ORIGIN,
            "webauthn.get",
            false
        );
        _assertInvalid(
            _entry(SCHEME_ARBITRARY, bytes32(0), witness), 0, 0.5 ether, "configured UV policy"
        );
    }

    function test_nonCanonicalWitnessIsRefused() public {
        _assertInvalid(
            _entry(SCHEME_ARBITRARY, bytes32(0), bytes.concat(_validAssertion(), hex"00")),
            0,
            0.5 ether,
            "trailing witness bytes"
        );
    }

    function test_costAboveCapIsRefused() public {
        _assertInvalid(
            _entry(SCHEME_ARBITRARY, bytes32(0), _validAssertion()),
            0,
            MAX_SPONSORED_COST + 1,
            "sponsorship cap"
        );
    }

    function test_scopeMustBeExactlyPayment() public {
        IFrameVm.FrameTxSignature memory signature =
            _entry(SCHEME_ARBITRARY, bytes32(0), _validAssertion());
        assertRefusesFrame(
            paymaster,
            _payContext(signature, 0, 0.5 ether, SCOPE_BOTH),
            "paymaster must not accept BOTH"
        );
        assertRefusesFrame(
            paymaster,
            _payContext(signature, 0, 0.5 ether, SCOPE_EXECUTION),
            "paymaster must not accept EXECUTION"
        );
        assertRefusesFrame(
            paymaster,
            _payContext(signature, 0, 0.5 ether, SCOPE_NONE),
            "paymaster must not accept NONE"
        );
    }

    function test_legacyArraySignatureSelectionAbiIsRefused() public {
        IFrameVm.FrameTx memory ctx = _payContext(
            _entry(SCHEME_ARBITRARY, bytes32(0), _validAssertion()), 0, 0.5 ether, SCOPE_PAYMENT
        );
        uint256[] memory legacyIndices = new uint256[](1);
        legacyIndices[0] = 0;
        ctx.frames[1].data = abi.encodeWithSignature("sponsorTransaction(uint256[])", legacyIndices);
        assertRefusesFrame(paymaster, ctx, "the removed dynamic-array ABI must not authorize");
    }

    function test_onlyOwnerMayWithdraw() public {
        WebAuthnPaymaster subject = WebAuthnPaymaster(payable(paymaster));
        vm.prank(address(0xBAD));
        vm.expectRevert(WebAuthnPaymaster.NotOwner.selector);
        subject.withdraw(payable(address(0xBEEF)), 1 wei);

        uint256 beforeBalance = address(0xBEEF).balance;
        subject.withdraw(payable(address(0xBEEF)), 1 wei);
        assertEq(address(0xBEEF).balance, beforeBalance + 1 wei, "owner withdrawal");
    }

    function test_invalidConstructorConfigurationIsRefused() public {
        vm.expectRevert(WebAuthnPaymaster.InvalidConfiguration.selector);
        new WebAuthnPaymaster(
            bytes32(0), bytes32(0), expectedRpIdHash, expectedOriginHash, true, MAX_SPONSORED_COST
        );

        vm.expectRevert(WebAuthnPaymaster.InvalidConfiguration.selector);
        new WebAuthnPaymaster(
            publicKeyX, publicKeyY, bytes32(0), expectedOriginHash, true, MAX_SPONSORED_COST
        );

        vm.expectRevert(WebAuthnPaymaster.InvalidConfiguration.selector);
        new WebAuthnPaymaster(
            publicKeyX, publicKeyY, expectedRpIdHash, bytes32(0), true, MAX_SPONSORED_COST
        );
    }
}
