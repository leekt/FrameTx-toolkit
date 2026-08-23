// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {WebAuthnVerifier} from "../crypto/WebAuthnVerifier.sol";

/// @title WebAuthnPaymaster
/// @notice Pays for an EIP-8141 transaction authorized by one WebAuthn credential.
/// @dev Every validation-time configuration value is immutable, so assertion checks do
///      not depend on mutable third-party storage. This remains a non-canonical paymaster
///      under the current EIP-8141 public-mempool policy.
contract WebAuthnPaymaster {
    address public immutable owner;
    bytes32 public immutable publicKeyX;
    bytes32 public immutable publicKeyY;
    bytes32 public immutable rpIdHash;
    /// @notice Keccak-256 of the exact UTF-8 WebAuthn origin.
    bytes32 public immutable originHash;
    bool public immutable requireUserVerification;
    uint256 public immutable maxSponsoredCost;

    error InvalidConfiguration();
    error NotOwner();
    error WithdrawFailed();
    error BadScheme(uint256 scheme);
    error ExplicitSignatureMessage();
    error InvalidWebAuthnAssertion();
    error CostTooHigh(uint256 maxCost);
    error InvalidApprovalScope(uint256 scope);

    constructor(
        bytes32 publicKeyX_,
        bytes32 publicKeyY_,
        bytes32 rpIdHash_,
        bytes32 originHash_,
        bool requireUserVerification_,
        uint256 maxSponsoredCost_
    ) payable {
        if (
            (publicKeyX_ == bytes32(0) && publicKeyY_ == bytes32(0)) || rpIdHash_ == bytes32(0)
                || originHash_ == bytes32(0)
        ) revert InvalidConfiguration();
        owner = msg.sender;
        publicKeyX = publicKeyX_;
        publicKeyY = publicKeyY_;
        rpIdHash = rpIdHash_;
        originHash = originHash_;
        requireUserVerification = requireUserVerification_;
        maxSponsoredCost = maxSponsoredCost_;
    }

    receive() external payable {}

    function withdraw(address payable to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert WithdrawFailed();
    }

    /// @notice Approve payment after validating the selected WebAuthn assertion.
    function sponsorTransaction(uint256 signatureIndex) external {
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

        uint256 maxCost = FrameTxLib.maxCost();
        if (maxCost > maxSponsoredCost) revert CostTooHigh(maxCost);

        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope != FrameTxLib.SCOPE_PAYMENT) revert InvalidApprovalScope(scope);
        FrameTxLib.approve(FrameTxLib.SCOPE_PAYMENT);
    }
}
