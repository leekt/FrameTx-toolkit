// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base64} from "solady/utils/Base64.sol";

import {IFormatter} from "./IFormatter.sol";

/// @title WebAuthnFormatter
/// @notice Pure WebAuthn-to-P256 message formatter for FrameKernel.
/// @dev This contract owns no credential and performs no P256 verification. `data` is the
///      canonical ABI encoding of
///      `(bytes clientDataPrefix, bytes clientDataSuffix, uint256 typeIndex,
///      uint256 crossOriginIndex)`.
///      `formatterProof` is the authenticator data returned by the authenticator. It remains
///      outside frame calldata because its counter is not known until after the challenge is
///      produced. This formatter always requires both user presence and user verification;
///      a different policy belongs in different pure formatter bytecode.
///
///      The caller supplies the browser's client-data structure with the challenge value
///      removed: `clientDataPrefix` must end in `"challenge":"`, and
///      `clientDataSuffix` must begin with the closing quote. The formatter inserts the
///      unpadded base64url encoding of `sigHash`, checks the WebAuthn type and flags, rejects
///      cross-origin assertions, then returns
///      `sha256(authenticatorData || sha256(clientDataJSON))`.
contract WebAuthnFormatter is IFormatter {
    uint256 public constant MAX_FORMAT_DATA_LENGTH = 2_048;
    uint256 public constant MIN_AUTHENTICATOR_DATA_LENGTH = 37;
    uint256 public constant MAX_AUTHENTICATOR_DATA_LENGTH = 1_024;
    uint256 public constant MAX_CLIENT_DATA_LENGTH = 1_024;

    bytes private constant CHALLENGE_MARKER = '"challenge":"';
    bytes private constant TYPE_MARKER = '"type":"webauthn.get"';
    bytes private constant CROSS_ORIGIN_MARKER = '"crossOrigin":false';
    bytes private constant TOP_ORIGIN_MARKER = '"topOrigin":';

    uint8 private constant FLAG_UP = 0x01;
    uint8 private constant FLAG_UV = 0x04;

    /// @inheritdoc IFormatter
    function format(bytes32 sigHash, bytes calldata data, bytes calldata formatterProof, uint256)
        external
        pure
        override
        returns (bytes32 messageHash)
    {
        if (data.length < 192 || data.length > MAX_FORMAT_DATA_LENGTH) return bytes32(0);

        (
            bytes memory clientDataPrefix,
            bytes memory clientDataSuffix,
            uint256 typeIndex,
            uint256 crossOriginIndex
        ) = abi.decode(data, (bytes, bytes, uint256, uint256));

        // Empty-msg ARBITRARY proof bytes are elided from the transaction signature hash,
        // but this formatter data is signed frame calldata. Canonical ABI still avoids
        // alternate transaction encodings for an identical template.
        if (
            keccak256(data)
                != keccak256(
                    abi.encode(clientDataPrefix, clientDataSuffix, typeIndex, crossOriginIndex)
                )
        ) {
            return bytes32(0);
        }

        uint256 authenticatorLength = formatterProof.length;
        if (
            authenticatorLength < MIN_AUTHENTICATOR_DATA_LENGTH
                || authenticatorLength > MAX_AUTHENTICATOR_DATA_LENGTH
                || clientDataPrefix.length < CHALLENGE_MARKER.length || clientDataSuffix.length == 0
        ) return bytes32(0);

        uint8 flags = uint8(formatterProof[32]);
        if (flags & FLAG_UP == 0) return bytes32(0);
        if (flags & FLAG_UV == 0) return bytes32(0);

        uint256 challengeMarkerOffset = clientDataPrefix.length - CHALLENGE_MARKER.length;
        if (!_matches(clientDataPrefix, challengeMarkerOffset, CHALLENGE_MARKER)) {
            return bytes32(0);
        }
        if (clientDataSuffix[0] != bytes1('"')) return bytes32(0);

        bytes memory encodedChallenge = bytes(Base64.encode(abi.encode(sigHash), true, true));
        bytes memory clientDataJSON =
            bytes.concat(clientDataPrefix, encodedChallenge, clientDataSuffix);
        if (clientDataJSON.length > MAX_CLIENT_DATA_LENGTH) return bytes32(0);
        if (!_matches(clientDataJSON, typeIndex, TYPE_MARKER)) return bytes32(0);
        if (!_matches(clientDataJSON, crossOriginIndex, CROSS_ORIGIN_MARKER)) return bytes32(0);
        if (_contains(clientDataJSON, TOP_ORIGIN_MARKER)) return bytes32(0);

        messageHash = sha256(abi.encodePacked(formatterProof, sha256(clientDataJSON)));
    }

    function _matches(bytes memory subject, uint256 offset, bytes memory expected)
        private
        pure
        returns (bool)
    {
        if (offset > subject.length || expected.length > subject.length - offset) return false;
        for (uint256 i; i < expected.length; ++i) {
            if (subject[offset + i] != expected[i]) return false;
        }
        return true;
    }

    function _contains(bytes memory subject, bytes memory expected) private pure returns (bool) {
        if (expected.length > subject.length) return false;
        uint256 lastOffset = subject.length - expected.length;
        for (uint256 offset; offset <= lastOffset; ++offset) {
            if (_matches(subject, offset, expected)) return true;
        }
        return false;
    }
}
