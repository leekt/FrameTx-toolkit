// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {IFrameAccount} from "./IFrameAccount.sol";

/// @title EOA7702FrameAccount
/// @notice Minimal Frame validation implementation intended for EIP-7702 delegation.
/// @dev When this runtime executes through a delegation indicator, `address(this)`
///      is the EOA authority. Frame validation therefore keeps the EOA's existing
///      secp256k1 identity without introducing proxy storage or an initializer.
///      The receive hook keeps plain ETH transfers usable after delegation.
contract EOA7702FrameAccount is IFrameAccount {
    error NoTrustedSignature();
    error NothingToApprove();

    /// @inheritdoc IFrameAccount
    function validate(uint256 signatureIndex) external override {
        // Preserve the original EOA's secp256k1 authority exactly. A different
        // native scheme resolving to the same 20-byte value must not silently
        // broaden the policy installed by the EIP-7702 authorization.
        if (FrameTxLib.sigScheme(signatureIndex) != FrameTxLib.SCHEME_SECP256K1) {
            revert NoTrustedSignature();
        }
        if (!FrameTxLib.signedThisTx(signatureIndex)) revert NoTrustedSignature();
        if (FrameTxLib.sigSigner(signatureIndex) != address(this)) {
            revert NoTrustedSignature();
        }

        // PAYMENT makes the delegated EOA a sponsor only: another sender must
        // already have approved execution, and this EOA gains no execution
        // authority in that transaction.
        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
        FrameTxLib.approve(scope);
    }

    receive() external payable {}
}
