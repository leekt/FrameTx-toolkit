// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {MLDSA44} from "../crypto/MLDSA44.sol";
import {IFrameAccount} from "./IFrameAccount.sol";

/// @title MLDSAAccount
/// @notice A single-key EIP-8141 account backed by native ML-DSA-44 scheme 0x03.
/// @dev The protocol validates the 1,312-byte public key and signature before
///      frame execution, then exposes the scheme-domain-separated signer
///      identity through SIGPARAM. This contract applies account policy only.
contract MLDSAAccount is IFrameAccount {
    address public mldsaSigner;

    error NotSelf();
    error NoTrustedSignature();
    error NothingToApprove();

    event MLDSAKeyChanged(address indexed signer);

    constructor(bytes memory publicKey) {
        mldsaSigner = MLDSA44.signerForKey(publicKey);
        emit MLDSAKeyChanged(mldsaSigner);
    }

    /// @notice Validate one selected native ML-DSA-44 entry and approve this frame's scope.
    function validate(uint256 signatureIndex) external override {
        if (FrameTxLib.sigScheme(signatureIndex) != FrameTxLib.SCHEME_ML_DSA_44) {
            revert NoTrustedSignature();
        }
        if (!FrameTxLib.signedThisTx(signatureIndex)) revert NoTrustedSignature();
        if (FrameTxLib.sigSigner(signatureIndex) != mldsaSigner) {
            revert NoTrustedSignature();
        }

        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
        FrameTxLib.approve(scope);
    }

    /// @notice Rotate the ML-DSA-44 key from a SENDER frame targeting this account.
    function setMLDSAKey(bytes calldata publicKey) external {
        if (msg.sender != address(this)) revert NotSelf();
        mldsaSigner = MLDSA44.signerForKey(publicKey);
        emit MLDSAKeyChanged(mldsaSigner);
    }

    /// @notice Derive the native signer identity for an exact ML-DSA-44 public key.
    function signerForKey(bytes calldata publicKey) external pure returns (address) {
        return MLDSA44.signerForKey(publicKey);
    }

    receive() external payable {}
}
