// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @notice EIP-8141 signature encoding, verified with the Osaka P256VERIFY precompile.
library VFrameP256 {
    uint256 internal constant N =
        0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;

    function verify(bytes32 digest, bytes calldata signature, address signer)
        internal
        view
        returns (bool)
    {
        if (signature.length != 128) return false;
        (uint256 r, uint256 s, bytes32 qx, bytes32 qy) =
            abi.decode(signature, (uint256, uint256, bytes32, bytes32));
        // The precompile accepts high-s; the frame signature format requires low-s.
        if (r == 0 || r >= N || s == 0 || s > N / 2) return false;
        if (address(uint160(uint256(keccak256(abi.encodePacked(qx, qy))))) != signer) {
            return false;
        }
        (bool success, bytes memory result) =
            address(0x100).staticcall{gas: 6900}(abi.encode(digest, r, s, qx, qy));
        // Fail closed when the precompile is absent or verification fails.
        return success && result.length == 32 && abi.decode(result, (uint256)) == 1;
    }
}
