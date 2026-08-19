// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";

/// @title P256Paymaster
/// @notice An EIP-8141 paymaster authorised by a protocol-verified P256 key.
contract P256Paymaster {
    address public immutable owner;
    address public immutable sponsorSigner;
    uint256 public immutable maxSponsoredCost;

    error InvalidPublicKey();
    error NotOwner();
    error WithdrawFailed();
    error NoTrustedSignature();
    error CostTooHigh(uint256 maxCost);
    error InvalidApprovalScope(uint256 scope);

    constructor(bytes32 sponsorQx, bytes32 sponsorQy, uint256 maxSponsoredCost_) payable {
        if (sponsorQx == bytes32(0) && sponsorQy == bytes32(0)) revert InvalidPublicKey();

        owner = msg.sender;
        sponsorSigner = address(uint160(uint256(keccak256(abi.encodePacked(sponsorQx, sponsorQy)))));
        maxSponsoredCost = maxSponsoredCost_;
    }

    receive() external payable {}

    function withdraw(address payable to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }

    /// @notice Approve payment when one selected canonical P256 entry was made
    ///         by the configured sponsor key.
    function sponsorTransaction(uint256[] calldata signatureIndices) external {
        address trustedSigner = sponsorSigner;
        bool trustedSignature;

        for (uint256 i; i < signatureIndices.length; ++i) {
            uint256 sigIndex = signatureIndices[i];
            if (FrameTxLib.sigScheme(sigIndex) != FrameTxLib.SCHEME_P256) continue;
            if (!FrameTxLib.signedThisTx(sigIndex)) continue;
            if (FrameTxLib.sigSigner(sigIndex) == trustedSigner) {
                trustedSignature = true;
                break;
            }
        }

        if (!trustedSignature) revert NoTrustedSignature();

        uint256 maxCost = FrameTxLib.maxCost();
        if (maxCost > maxSponsoredCost) revert CostTooHigh(maxCost);

        // A third-party paymaster must be a dedicated `pay` frame. Requiring
        // the exact scope avoids accepting a frame that also advertises an
        // execution permission the paymaster can never legitimately grant.
        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope != FrameTxLib.SCOPE_PAYMENT) revert InvalidApprovalScope(scope);
        FrameTxLib.approve(FrameTxLib.SCOPE_PAYMENT);
    }
}
