// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {IFrameAccount} from "./IFrameAccount.sol";

/// @title EOA7702FrameAccount
/// @notice Minimal dual-mode implementation intended for EIP-7702 delegation.
/// @dev When this runtime executes through a delegation indicator, `address(this)`
///      is the EOA authority. Frame validation therefore keeps the EOA's existing
///      secp256k1 identity without introducing proxy storage or an initializer.
///      The ordinary execution entry point remains self-only: the authority can
///      call itself from a legacy or set-code transaction, while third parties
///      cannot turn the delegation into a public executor.
contract EOA7702FrameAccount is IFrameAccount {
    error NoTrustedSignature();
    error NothingToApprove();
    error NotAuthority();
    error ExecutionFailed(bytes reason);

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

        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
        FrameTxLib.approve(scope);
    }

    /// @notice Preserve a narrow EOA-originated execution path after delegation.
    /// @dev Under EIP-7702 the authority sends a transaction to itself, making
    ///      both `msg.sender` and `address(this)` the authority address.
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result)
    {
        if (msg.sender != address(this)) revert NotAuthority();
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) revert ExecutionFailed(result);
    }

    receive() external payable {}
}
