// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Common validation entry point for EIP-8141 smart accounts.
/// @dev The indices select entries from `tx.signatures`. Frame calldata is part
///      of the canonical transaction signature hash, so canonical signatures
///      commit to this routing information together with the rest of the frame
///      list.
interface IFrameAccount {
    function validate(uint256[] calldata signatureIndices) external;
}
