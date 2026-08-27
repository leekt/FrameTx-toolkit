// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @title IFormatter
/// @notice Stateless transformation from signed frame data to a message digest.
/// @dev A formatter does not authorize a key and must not approve a frame. FrameKernel
///      verifies the resulting digest against an account-authorized P256 public key.
interface IFormatter {
    /// @param sigHash Canonical EIP-8141 signature hash committed by the frame transaction.
    /// @param data Formatter-specific data committed in the validation frame calldata.
    /// @param formatterProof Formatter-specific response data elided from `sigHash`.
    /// @param signatureIndex Selected transaction-signature index.
    function format(
        bytes32 sigHash,
        bytes calldata data,
        bytes calldata formatterProof,
        uint256 signatureIndex
    ) external pure returns (bytes32 messageHash);
}
