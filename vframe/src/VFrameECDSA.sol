// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

library VFrameECDSA {
    error InvalidSignature();

    /// @dev Standard 65-byte r || s || v, with v = 27/28 and canonical low s.
    function recover(bytes32 digest, bytes calldata signature)
        internal
        pure
        returns (address signer)
    {
        if (signature.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (
            uint256(s) > 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0
                || (v != 27 && v != 28)
        ) revert InvalidSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }
}
