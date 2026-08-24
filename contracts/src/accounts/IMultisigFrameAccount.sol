// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Validation entry point for EIP-8141 accounts that aggregate signatures.
/// @dev The indices select entries from `tx.signatures`. This array ABI is
///      intentionally limited to multisig accounts; ordinary accounts use the
///      single-index `IFrameAccount` ABI. A PAYMENT-only VERIFY frame can use
///      this same entry point to make the multisig a sponsor without granting
///      it execution authority in that transaction.
interface IMultisigFrameAccount {
    function validate(uint256[] calldata signatureIndices) external;
}
