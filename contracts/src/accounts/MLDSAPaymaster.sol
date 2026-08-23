// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {MLDSA44} from "../crypto/MLDSA44.sol";

/// @title MLDSAPaymaster
/// @notice An EIP-8141 paymaster authorised by native ML-DSA-44 scheme 0x03.
contract MLDSAPaymaster {
    address public immutable owner;
    address public immutable sponsorSigner;
    uint256 public immutable maxSponsoredCost;

    error NotOwner();
    error WithdrawFailed();
    error NoTrustedSignature();
    error CostTooHigh(uint256 maxCost);
    error InvalidApprovalScope(uint256 scope);

    constructor(bytes memory sponsorPublicKey, uint256 maxSponsoredCost_) payable {
        owner = msg.sender;
        sponsorSigner = MLDSA44.signerForKey(sponsorPublicKey);
        maxSponsoredCost = maxSponsoredCost_;
    }

    receive() external payable {}

    function withdraw(address payable to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }

    /// @notice Approve payment when the selected canonical ML-DSA-44 entry was
    ///         made by the configured sponsor key.
    function sponsorTransaction(uint256 signatureIndex) external {
        if (FrameTxLib.sigScheme(signatureIndex) != FrameTxLib.SCHEME_ML_DSA_44) {
            revert NoTrustedSignature();
        }
        if (!FrameTxLib.signedThisTx(signatureIndex)) revert NoTrustedSignature();
        if (FrameTxLib.sigSigner(signatureIndex) != sponsorSigner) {
            revert NoTrustedSignature();
        }

        uint256 maxCost = FrameTxLib.maxCost();
        if (maxCost > maxSponsoredCost) revert CostTooHigh(maxCost);

        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope != FrameTxLib.SCOPE_PAYMENT) revert InvalidApprovalScope(scope);
        FrameTxLib.approve(FrameTxLib.SCOPE_PAYMENT);
    }

    function signerForKey(bytes calldata publicKey) external pure returns (address) {
        return MLDSA44.signerForKey(publicKey);
    }
}
