// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {IFrameAccount} from "./IFrameAccount.sol";

/// @title P256Account
/// @notice A single-key EIP-8141 account backed by a secp256r1 (P256) key.
/// @dev The protocol verifies the P256 signature and public key before frame
///      execution. This account stores only the key-derived signer address and
///      applies policy to the explicitly selected signature entries.
contract P256Account is IFrameAccount {
    /// @notice `keccak256(qx || qy)[12:]` for the currently authorised key.
    address public p256Signer;

    error InvalidPublicKey();
    error NotSelf();
    error NoTrustedSignature();
    error NothingToApprove();

    event P256KeyChanged(address indexed signer);

    constructor(bytes32 qx, bytes32 qy) {
        p256Signer = _signerForKey(qx, qy);
        emit P256KeyChanged(p256Signer);
    }

    /// @notice VERIFY-frame entry point using the shared account ABI.
    /// @param signatureIndices Entries assigned to this account by the signed
    ///        frame transaction.
    function validate(uint256[] calldata signatureIndices) external override {
        address trustedSigner = p256Signer;
        bool trustedSignature;

        for (uint256 i; i < signatureIndices.length; ++i) {
            uint256 sigIndex = signatureIndices[i];

            // Only protocol-validated P256 entries belong to this policy.
            // Checking the scheme first also avoids asking for a signer on an
            // ARBITRARY entry, which would halt exceptionally.
            if (FrameTxLib.sigScheme(sigIndex) != FrameTxLib.SCHEME_P256) continue;
            if (!FrameTxLib.signedThisTx(sigIndex)) continue;
            if (FrameTxLib.sigSigner(sigIndex) == trustedSigner) {
                trustedSignature = true;
                break;
            }
        }

        if (!trustedSignature) revert NoTrustedSignature();

        // The same account can self-relay, be sponsored, or pay for another
        // sender. The VERIFY frame's signed flags select the requested role.
        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
        FrameTxLib.approve(scope);
    }

    /// @notice Rotate the P256 key from a SENDER frame targeting this account.
    function setP256Key(bytes32 qx, bytes32 qy) external {
        if (msg.sender != address(this)) revert NotSelf();
        p256Signer = _signerForKey(qx, qy);
        emit P256KeyChanged(p256Signer);
    }

    /// @notice Derive the EIP-8141 signer identity for a P256 public key.
    function signerForKey(bytes32 qx, bytes32 qy) external pure returns (address) {
        return _signerForKey(qx, qy);
    }

    function _signerForKey(bytes32 qx, bytes32 qy) private pure returns (address signer) {
        if (qx == bytes32(0) && qy == bytes32(0)) revert InvalidPublicKey();
        signer = address(uint160(uint256(keccak256(abi.encodePacked(qx, qy)))));
    }

    /// @dev APPROVE_PAYMENT requires the chosen payer to hold the maximum cost.
    receive() external payable {}
}
