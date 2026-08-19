// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title P256Verifier
/// @notice Minimal wrapper around the EIP-7951 P256VERIFY precompile.
library P256Verifier {
    address internal constant P256VERIFY = address(0x100);

    uint256 internal constant P256_N =
        0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    uint256 internal constant P256_HALF_N =
        0x7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8;

    /// @notice Whether `(r, s)` is a unique, low-s P256 signature encoding.
    /// @dev P256VERIFY accepts the mathematically equivalent high-s form. The
    ///      low-s restriction prevents a third party from changing an otherwise
    ///      valid ARBITRARY witness without the credential.
    function isCanonicalSignature(bytes32 r, bytes32 s) internal pure returns (bool) {
        uint256 rValue = uint256(r);
        uint256 sValue = uint256(s);
        return rValue != 0 && rValue < P256_N && sValue != 0 && sValue <= P256_HALF_N;
    }

    /// @notice Verify a prehashed P256 signature with an uncompressed key's coordinates.
    /// @dev The precompile input is exactly `digest || r || s || qx || qy`.
    function verify(bytes32 digest, bytes32 r, bytes32 s, bytes32 qx, bytes32 qy)
        internal
        view
        returns (bool)
    {
        if (!isCanonicalSignature(r, s)) return false;
        if (qx == bytes32(0) && qy == bytes32(0)) return false;

        bytes memory input = abi.encodePacked(digest, r, s, qx, qy);
        (bool success, bytes memory output) = P256VERIFY.staticcall(input);
        if (!success || output.length != 32) return false;

        uint256 result;
        assembly ("memory-safe") {
            result := mload(add(output, 0x20))
        }
        return result == 1;
    }
}
