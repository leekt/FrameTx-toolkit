// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

library VFrameECDSA {
    /// @dev EIP-8141-shaped 65-byte v || r || s, with v = 0/1 and canonical low s.
    /// Returns zero for malformed or invalid signatures.
    function recover(bytes32 digest, bytes memory signature)
        internal
        pure
        returns (address signer)
    {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            v := byte(0, mload(add(signature, 32)))
            r := mload(add(signature, 33))
            s := mload(add(signature, 65))
        }
        if (
            uint256(s) > 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0 || v > 1
        ) return address(0);
        signer = ecrecover(digest, v + 27, r, s);
    }
}
