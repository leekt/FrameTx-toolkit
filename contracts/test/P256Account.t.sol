// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFrameVm} from "./FrameTest.sol";
import {AccountTestSuite} from "./AccountTestSuite.sol";
import {P256Account} from "../src/accounts/P256Account.sol";

/// P256 account policy tests. The reusable suite supplies all three account
/// roles; the focused cases below pin this implementation's scheme and key
/// policy. `setFrameTx` supplies already-verified signature metadata, just as
/// it does for the other protocol-signature account fixtures.
contract P256AccountTest is AccountTestSuite {
    uint8 private constant SCHEME_SECP256K1 = 1;
    uint8 private constant SCHEME_P256 = 2;
    uint8 private constant SCHEME_ML_DSA_44 = 3;
    uint256 private constant P256_KEY =
        0x234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1;
    uint256 private constant OTHER_P256_KEY =
        0x34567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef12;

    address internal account;
    bytes32 internal qx;
    bytes32 internal qy;
    address internal signer;

    function setUp() public {
        (uint256 x, uint256 y) = vm.publicKeyP256(P256_KEY);
        qx = bytes32(x);
        qy = bytes32(y);
        signer = _signer(qx, qy);
        account = deployAccountWithArgs("P256Account", abi.encode(qx, qy));

        assertEq(P256Account(payable(account)).p256Signer(), signer, "constructor key identity");
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
        signatures[0] = _signature(SCHEME_P256, signer, bytes32(0));
    }

    function accountUnauthorizedSignatures()
        internal
        pure
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        (uint256 otherX, uint256 otherY) = vm.publicKeyP256(OTHER_P256_KEY);
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] =
            _signature(SCHEME_P256, _signer(bytes32(otherX), bytes32(otherY)), bytes32(0));
    }

    function _signer(bytes32 x, bytes32 y) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    function _signature(uint8 scheme, address claimedSigner, bytes32 msgHash)
        internal
        pure
        returns (IFrameVm.FrameTxSignature memory)
    {
        return IFrameVm.FrameTxSignature({
            scheme: scheme,
            signer: claimedSigner,
            msgHash: msgHash,
            // Protocol signatures are opaque to account bytecode. The
            // synthetic host fixture therefore needs only their metadata.
            signature: ""
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

    function test_p256SignerUsesProtocolKeyDerivation() public view {
        assertEq(
            P256Account(payable(account)).signerForKey(qx, qy),
            signer,
            "signer must be keccak256(qx || qy)[12:]"
        );
    }

    function test_secp256k1EntryFromSameAddressIsRefused() public {
        assertRefusesFrame(
            account,
            _context(SCHEME_SECP256K1, signer, bytes32(0), 0, SCOPE_BOTH),
            "this policy must require the P256 protocol scheme"
        );
    }

    function test_mldsaEntryFromSameAddressIsRefused() public {
        assertRefusesFrame(
            account,
            _context(SCHEME_ML_DSA_44, signer, bytes32(0), 0, SCOPE_BOTH),
            "an ML-DSA-44 identity must not masquerade as the configured P256 key"
        );
    }

    function test_explicitDigestP256EntryIsRefused() public {
        assertRefusesFrame(
            account,
            _context(SCHEME_P256, signer, keccak256("unrelated"), 0, SCOPE_BOTH),
            "an explicit digest does not bind the frame transaction"
        );
    }

    function test_differentP256SignerIsRefused() public {
        (uint256 otherX, uint256 otherY) = vm.publicKeyP256(OTHER_P256_KEY);
        address otherSigner = _signer(bytes32(otherX), bytes32(otherY));
        assertRefusesFrame(
            account,
            _context(SCHEME_P256, otherSigner, bytes32(0), 0, SCOPE_BOTH),
            "only the configured P256 key may authorise"
        );
    }

    function test_keyRotationRequiresSelfAndReplacesAuthority() public {
        (uint256 nextX, uint256 nextY) = vm.publicKeyP256(OTHER_P256_KEY);
        bytes32 nextQx = bytes32(nextX);
        bytes32 nextQy = bytes32(nextY);
        address nextSigner = _signer(nextQx, nextQy);
        P256Account subject = P256Account(payable(account));

        vm.expectRevert(P256Account.NotSelf.selector);
        subject.setP256Key(nextQx, nextQy);

        // Models a SENDER frame targeting the account, where the protocol sets
        // msg.sender to the account itself.
        vm.prank(account);
        subject.setP256Key(nextQx, nextQy);
        assertEq(subject.p256Signer(), nextSigner, "new key must become authoritative");

        assertRefusesFrame(
            account,
            _context(SCHEME_P256, signer, bytes32(0), 0, SCOPE_BOTH),
            "the old key must stop authorising immediately"
        );
        assertApprovesFrame(
            account,
            _context(SCHEME_P256, nextSigner, bytes32(0), 0, SCOPE_BOTH),
            "the rotated key must authorise"
        );
    }

    function test_allZeroPublicKeyIsRefused() public {
        vm.expectRevert(P256Account.InvalidPublicKey.selector);
        new P256Account(bytes32(0), bytes32(0));
    }
}
