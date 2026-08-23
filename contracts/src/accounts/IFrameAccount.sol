// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Common validation entry point for single-signature EIP-8141 smart accounts.
/// @dev The index selects one entry from `tx.signatures`. Frame calldata is part
///      of the canonical transaction signature hash, so a canonical signature
///      commits to this routing information together with the rest of the frame
///      list. Accounts that aggregate multiple signatures use
///      `IMultisigFrameAccount` instead.
interface IFrameAccount {
    function validate(uint256 signatureIndex) external;
}
