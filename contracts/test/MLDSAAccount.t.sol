// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFrameVm} from "./FrameTest.sol";
import {AccountTestSuite} from "./AccountTestSuite.sol";
import {MLDSAAccount} from "../src/accounts/MLDSAAccount.sol";
import {MLDSA44} from "../src/crypto/MLDSA44.sol";

/// Native ML-DSA-44 account policy tests. The frame fixture supplies metadata
/// that the protocol has already verified; native signature bytes are opaque
/// to the account and belong in the raw transaction integration suite.
contract MLDSAAccountTest is AccountTestSuite {
    uint8 private constant SCHEME_SECP256K1 = 1;
    uint8 private constant SCHEME_P256 = 2;
    uint8 private constant SCHEME_ML_DSA_44 = 3;

    address internal account;
    address internal signer;
    bytes internal publicKey;

    function setUp() public {
        publicKey = _publicKey(0x11);
        signer = _signer(publicKey);
        account = deployAccountWithArgs("MLDSAAccount", abi.encode(publicKey));

        assertEq(MLDSAAccount(payable(account)).mldsaSigner(), signer, "constructor key identity");
    }

    function accountUnderTest() internal view override returns (address) {
        return account;
    }

    function accountAuthorizationSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _signature(SCHEME_ML_DSA_44, signer, bytes32(0));
    }

    function accountUnauthorizedSignatures()
        internal
        pure
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _signature(SCHEME_ML_DSA_44, _signer(_publicKey(0x92)), bytes32(0));
    }

    function _publicKey(uint256 seed) internal pure returns (bytes memory key) {
        key = new bytes(1_312);
        for (uint256 i; i < key.length; ++i) {
            key[i] = bytes1(uint8((seed + i) & 0xff));
        }
    }

    function _signer(bytes memory key) internal pure returns (address) {
        require(key.length == 1_312, "test key length");
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0x03), key)))));
    }

    function _signature(uint8 scheme, address claimedSigner, bytes32 msgHash)
        internal
        pure
        returns (IFrameVm.FrameTxSignature memory)
    {
        return IFrameVm.FrameTxSignature({
            scheme: scheme, signer: claimedSigner, msgHash: msgHash, signature: ""
        });
    }

    function _context(
        uint8 scheme,
        address claimedSigner,
        bytes32 msgHash,
        uint256 signatureIndex,
        uint64 scope
    ) internal view returns (IFrameVm.FrameTx memory ctx) {
        ctx = verifyContext(account, scope, bytes32(uint256(0x8141)));
        ctx.frames[0].data = validationCalldata(signatureIndex);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = _signature(scheme, claimedSigner, msgHash);
    }

    function test_signerUsesSchemeDomainSeparatedPublicKeyDerivation() public view {
        assertEq(
            MLDSAAccount(payable(account)).signerForKey(publicKey),
            signer,
            "signer must be low20(keccak256(0x03 || publicKey))"
        );
    }

    function test_secp256k1EntryFromSameAddressIsRefused() public {
        assertRefusesFrame(
            account,
            _context(SCHEME_SECP256K1, signer, bytes32(0), 0, SCOPE_BOTH),
            "this policy must require native ML-DSA-44"
        );
    }

    function test_p256EntryFromSameAddressIsRefused() public {
        assertRefusesFrame(
            account,
            _context(SCHEME_P256, signer, bytes32(0), 0, SCOPE_BOTH),
            "a P256 entry must not masquerade as ML-DSA-44"
        );
    }

    function test_explicitDigestEntryIsRefused() public {
        assertRefusesFrame(
            account,
            _context(SCHEME_ML_DSA_44, signer, keccak256("unrelated"), 0, SCOPE_BOTH),
            "an explicit digest does not bind the frame transaction"
        );
    }

    function test_differentMLDSASignerIsRefused() public {
        address otherSigner = _signer(_publicKey(0x92));
        assertRefusesFrame(
            account,
            _context(SCHEME_ML_DSA_44, otherSigner, bytes32(0), 0, SCOPE_BOTH),
            "only the configured ML-DSA-44 key may authorise"
        );
    }

    function test_keyRotationRequiresSelfAndReplacesAuthority() public {
        bytes memory nextKey = _publicKey(0x5a);
        address nextSigner = _signer(nextKey);
        MLDSAAccount subject = MLDSAAccount(payable(account));

        vm.expectRevert(MLDSAAccount.NotSelf.selector);
        subject.setMLDSAKey(nextKey);

        vm.prank(account);
        subject.setMLDSAKey(nextKey);
        assertEq(subject.mldsaSigner(), nextSigner, "new key must become authoritative");

        assertRefusesFrame(
            account,
            _context(SCHEME_ML_DSA_44, signer, bytes32(0), 0, SCOPE_BOTH),
            "the old key must stop authorising immediately"
        );
        assertApprovesFrame(
            account,
            _context(SCHEME_ML_DSA_44, nextSigner, bytes32(0), 0, SCOPE_BOTH),
            "the rotated key must authorise"
        );
    }

    function test_constructorRequiresExactPublicKeyLength() public {
        bytes memory emptyKey = new bytes(0);
        vm.expectRevert(
            abi.encodeWithSelector(MLDSA44.InvalidPublicKeyLength.selector, emptyKey.length)
        );
        new MLDSAAccount(emptyKey);

        bytes memory shortKey = new bytes(1_311);
        vm.expectRevert(
            abi.encodeWithSelector(MLDSA44.InvalidPublicKeyLength.selector, shortKey.length)
        );
        new MLDSAAccount(shortKey);

        bytes memory longKey = new bytes(1_313);
        vm.expectRevert(
            abi.encodeWithSelector(MLDSA44.InvalidPublicKeyLength.selector, longKey.length)
        );
        new MLDSAAccount(longKey);
    }

    function test_rotationRequiresExactPublicKeyLength() public {
        bytes memory emptyKey = new bytes(0);
        vm.startPrank(account);
        vm.expectRevert(
            abi.encodeWithSelector(MLDSA44.InvalidPublicKeyLength.selector, emptyKey.length)
        );
        MLDSAAccount(payable(account)).setMLDSAKey(emptyKey);
        vm.stopPrank();

        bytes memory shortKey = new bytes(1_311);
        vm.startPrank(account);
        vm.expectRevert(
            abi.encodeWithSelector(MLDSA44.InvalidPublicKeyLength.selector, shortKey.length)
        );
        MLDSAAccount(payable(account)).setMLDSAKey(shortKey);
        vm.stopPrank();

        bytes memory longKey = new bytes(1_313);
        vm.startPrank(account);
        vm.expectRevert(
            abi.encodeWithSelector(MLDSA44.InvalidPublicKeyLength.selector, longKey.length)
        );
        MLDSAAccount(payable(account)).setMLDSAKey(longKey);
        vm.stopPrank();
    }

    function test_legacyArraySignatureSelectionAbiIsRefused() public {
        IFrameVm.FrameTx memory ctx = _context(SCHEME_ML_DSA_44, signer, bytes32(0), 0, SCOPE_BOTH);
        uint256[] memory legacyIndices = new uint256[](1);
        legacyIndices[0] = 0;
        ctx.frames[0].data = abi.encodeWithSignature("validate(uint256[])", legacyIndices);
        assertRefusesFrame(account, ctx, "the removed dynamic-array ABI must not authorize");
    }
}
