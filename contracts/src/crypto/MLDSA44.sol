// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title MLDSA44
/// @notice Key-shape and signer-identity helpers for the native ML-DSA-44
///         EIP-8141 profile used by this toolkit.
/// @dev Cryptographic verification is performed by the protocol before frame
///      execution. The contract layer receives only the verified signer
///      identity through SIGPARAM.
library MLDSA44 {
    uint256 internal constant PUBLIC_KEY_LENGTH = 1_312;
    uint8 internal constant SCHEME = 0x03;

    error InvalidPublicKeyLength(uint256 length);

    /// @notice Derive the scheme-domain-separated EIP-8141 signer identity.
    /// @dev The low 20 bytes of keccak256(0x03 || publicKey) match the native
    ///      protocol verifier's resolved-signer derivation.
    function signerForKey(bytes memory publicKey) internal pure returns (address signer) {
        if (publicKey.length != PUBLIC_KEY_LENGTH) {
            revert InvalidPublicKeyLength(publicKey.length);
        }
        signer = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(SCHEME), publicKey)))));
    }
}
