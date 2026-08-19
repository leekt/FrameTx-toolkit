// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Base64Url
/// @notice Unpadded base64url encoding for a WebAuthn 32-byte challenge.
library Base64Url {
    string internal constant TABLE =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    /// @notice Encode 32 bytes as the canonical 43-character, unpadded base64url string.
    function encode32(bytes32 input) internal pure returns (bytes memory output) {
        bytes memory table = bytes(TABLE);
        output = new bytes(43);

        uint256 outputIndex;
        for (uint256 inputIndex; inputIndex < 30; inputIndex += 3) {
            uint24 chunk = (uint24(uint8(input[inputIndex])) << 16)
                | (uint24(uint8(input[inputIndex + 1])) << 8) | uint24(uint8(input[inputIndex + 2]));
            output[outputIndex++] = table[(chunk >> 18) & 0x3f];
            output[outputIndex++] = table[(chunk >> 12) & 0x3f];
            output[outputIndex++] = table[(chunk >> 6) & 0x3f];
            output[outputIndex++] = table[chunk & 0x3f];
        }

        uint16 tail = (uint16(uint8(input[30])) << 8) | uint16(uint8(input[31]));
        output[40] = table[(tail >> 10) & 0x3f];
        output[41] = table[(tail >> 4) & 0x3f];
        output[42] = table[(tail << 2) & 0x3f];
    }
}
