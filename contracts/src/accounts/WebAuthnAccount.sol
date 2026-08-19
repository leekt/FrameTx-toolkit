// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {WebAuthnVerifier} from "../crypto/WebAuthnVerifier.sol";
import {IFrameAccount} from "./IFrameAccount.sol";

/// @title WebAuthnAccount
/// @notice Single-credential EIP-8141 account authorized by a WebAuthn assertion.
/// @dev WebAuthn does not sign the transaction hash directly. The assertion therefore
///      lives in an empty-msg ARBITRARY signature entry: its client-data challenge binds
///      to the canonical hash, and this contract performs the full assertion verification.
contract WebAuthnAccount is IFrameAccount {
    bytes32 public immutable publicKeyX;
    bytes32 public immutable publicKeyY;
    bytes32 public immutable rpIdHash;
    /// @notice Keccak-256 of the exact UTF-8 WebAuthn origin.
    bytes32 public immutable originHash;
    bool public immutable requireUserVerification;

    error InvalidConfiguration();
    error ExpectedOneSignature();
    error BadScheme(uint256 scheme);
    error ExplicitSignatureMessage();
    error InvalidWebAuthnAssertion();
    error NothingToApprove();

    constructor(
        bytes32 publicKeyX_,
        bytes32 publicKeyY_,
        bytes32 rpIdHash_,
        bytes32 originHash_,
        bool requireUserVerification_
    ) {
        if (
            (publicKeyX_ == bytes32(0) && publicKeyY_ == bytes32(0)) || rpIdHash_ == bytes32(0)
                || originHash_ == bytes32(0)
        ) revert InvalidConfiguration();
        publicKeyX = publicKeyX_;
        publicKeyY = publicKeyY_;
        rpIdHash = rpIdHash_;
        originHash = originHash_;
        requireUserVerification = requireUserVerification_;
    }

    /// @notice Validate the one selected WebAuthn assertion and approve this frame's scope.
    function validate(uint256[] calldata signatureIndices) external override {
        if (signatureIndices.length != 1) revert ExpectedOneSignature();
        uint256 signatureIndex = signatureIndices[0];

        uint256 scheme = FrameTxLib.sigScheme(signatureIndex);
        if (scheme != FrameTxLib.SCHEME_ARBITRARY) revert BadScheme(scheme);
        if (!FrameTxLib.signedThisTx(signatureIndex)) revert ExplicitSignatureMessage();

        uint256 witnessLength = FrameTxLib.sigLength(signatureIndex);
        if (!WebAuthnVerifier.isValidWitnessLength(witnessLength)) {
            revert InvalidWebAuthnAssertion();
        }

        WebAuthnVerifier.Credential memory credential = WebAuthnVerifier.Credential({
            publicKeyX: publicKeyX,
            publicKeyY: publicKeyY,
            rpIdHash: rpIdHash,
            originHash: originHash,
            requireUserVerification: requireUserVerification
        });
        if (!WebAuthnVerifier.verify(
                FrameTxLib.sigDataSlice(signatureIndex, 0, witnessLength),
                FrameTxLib.sigHash(),
                credential
            )) revert InvalidWebAuthnAssertion();

        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
        FrameTxLib.approve(scope);
    }

    receive() external payable {}
}
