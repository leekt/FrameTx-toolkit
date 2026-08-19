// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base64Url} from "./Base64Url.sol";
import {P256Verifier} from "./P256Verifier.sol";

/// @title WebAuthnVerifier
/// @notice Strict WebAuthn assertion verification for an EIP-8141 ARBITRARY witness.
/// @dev This initial profile deliberately accepts only the common 37-byte assertion
///      authenticator data form without extensions and the canonical client-data JSON
///      serialization documented below. Credential registration and attestation are
///      outside its scope.
library WebAuthnVerifier {
    uint256 internal constant MAX_WITNESS_LENGTH = 2_048;
    uint256 internal constant AUTHENTICATOR_DATA_LENGTH = 37;

    uint8 private constant FLAG_UP = 0x01;
    uint8 private constant FLAG_RFU_MASK = 0x22;
    uint8 private constant FLAG_UV = 0x04;
    uint8 private constant FLAG_BE = 0x08;
    uint8 private constant FLAG_BS = 0x10;
    uint8 private constant FLAG_AT_OR_ED = 0xc0;

    struct Credential {
        bytes32 publicKeyX;
        bytes32 publicKeyY;
        bytes32 rpIdHash;
        /// @dev Keccak-256 of the exact UTF-8 origin string.
        bytes32 originHash;
        bool requireUserVerification;
    }

    struct Assertion {
        bytes32 r;
        bytes32 s;
        bytes authenticatorData;
        bytes clientDataJSON;
    }

    /// @notice Whether an ARBITRARY entry is small enough to copy and large
    ///         enough to contain this profile's canonical ABI witness.
    /// @dev Check this against SIGPARAM length before SIGDATACOPY so an
    ///      oversized witness cannot force a needless memory allocation.
    function isValidWitnessLength(uint256 encodedLength) internal pure returns (bool) {
        return encodedLength >= 256 && encodedLength <= MAX_WITNESS_LENGTH;
    }

    /// @notice Verify one canonically encoded WebAuthn assertion.
    /// @param encodedAssertion Exact ABI encoding of
    ///        `(bytes32 r, bytes32 s, bytes authenticatorData, bytes clientDataJSON)`.
    /// @param challenge The canonical EIP-8141 transaction signature hash.
    function verify(bytes memory encodedAssertion, bytes32 challenge, Credential memory credential)
        internal
        view
        returns (bool)
    {
        (bool decoded, Assertion memory assertion) = _decodeCanonical(encodedAssertion);
        if (!decoded) return false;
        if (!_validAuthenticatorData(assertion.authenticatorData, credential)) return false;
        if (!_validClientData(assertion.clientDataJSON, challenge, credential.originHash)) {
            return false;
        }

        bytes32 clientDataHash = sha256(assertion.clientDataJSON);
        bytes32 digest = sha256(abi.encodePacked(assertion.authenticatorData, clientDataHash));
        return P256Verifier.verify(
            digest, assertion.r, assertion.s, credential.publicKeyX, credential.publicKeyY
        );
    }

    /// @dev Enforces the normal ABI layout, zero padding, and absence of trailing bytes.
    ///      This matters because an empty-msg ARBITRARY witness is elided from the
    ///      canonical signature hash and must not admit avoidable alternate encodings.
    function _decodeCanonical(bytes memory encoded)
        private
        pure
        returns (bool ok, Assertion memory assertion)
    {
        uint256 encodedLength = encoded.length;
        if (!isValidWitnessLength(encodedLength)) return (false, assertion);

        uint256 authenticatorDataOffset;
        uint256 clientDataOffset;
        uint256 authenticatorDataLength;
        uint256 clientDataLength;
        assembly ("memory-safe") {
            // ABI offsets are relative to the first byte after the bytes length word.
            authenticatorDataOffset := mload(add(encoded, 0x60))
            clientDataOffset := mload(add(encoded, 0x80))
            authenticatorDataLength := mload(add(encoded, 0xa0))
            clientDataLength := mload(add(encoded, 0x100))
        }

        // Four-word head, followed by the 37-byte authenticator data tail.
        if (authenticatorDataOffset != 0x80 || clientDataOffset != 0xe0) {
            return (false, assertion);
        }
        if (authenticatorDataLength != AUTHENTICATOR_DATA_LENGTH) return (false, assertion);

        // The bound makes the addition and rounding below safe independently of
        // attacker-controlled ABI words.
        if (clientDataLength > MAX_WITNESS_LENGTH - 256) return (false, assertion);
        uint256 paddedClientDataLength = (clientDataLength + 31) & ~uint256(31);
        if (encodedLength != 256 + paddedClientDataLength) return (false, assertion);

        (assertion.r, assertion.s, assertion.authenticatorData, assertion.clientDataJSON) =
            abi.decode(encoded, (bytes32, bytes32, bytes, bytes));

        // Reject non-zero dynamic padding and every other non-canonical encoding.
        if (
            keccak256(encoded)
                != keccak256(
                    abi.encode(
                        assertion.r,
                        assertion.s,
                        assertion.authenticatorData,
                        assertion.clientDataJSON
                    )
                )
        ) return (false, assertion);

        return (true, assertion);
    }

    function _validAuthenticatorData(bytes memory authenticatorData, Credential memory credential)
        private
        pure
        returns (bool)
    {
        if (authenticatorData.length != AUTHENTICATOR_DATA_LENGTH) return false;

        bytes32 actualRpIdHash;
        assembly ("memory-safe") {
            actualRpIdHash := mload(add(authenticatorData, 0x20))
        }
        if (actualRpIdHash != credential.rpIdHash) return false;

        uint8 flags = uint8(authenticatorData[32]);
        if (flags & FLAG_UP == 0) return false;
        if (credential.requireUserVerification && flags & FLAG_UV == 0) return false;
        if (flags & FLAG_RFU_MASK != 0 || flags & FLAG_AT_OR_ED != 0) return false;
        // A credential cannot be in the backed-up state unless it is backup eligible.
        if (flags & FLAG_BS != 0 && flags & FLAG_BE == 0) return false;
        return true;
    }

    /// @dev Accepted serialization (with no padding in the challenge):
    ///      {"type":"webauthn.get","challenge":"<43 chars>","origin":"<origin>","crossOrigin":false}
    ///      Requiring this exact form avoids ambiguous JSON parsing, duplicate keys,
    ///      unexpected top origins, and silent acceptance of attacker-selected offsets.
    function _validClientData(bytes memory clientData, bytes32 challenge, bytes32 originHash)
        private
        pure
        returns (bool)
    {
        bytes memory prefix = bytes('{"type":"webauthn.get","challenge":"');
        bytes memory originMarker = bytes("\",\"origin\":\"");
        bytes memory suffix = bytes("\",\"crossOrigin\":false}");
        bytes memory encodedChallenge = Base64Url.encode32(challenge);

        uint256 challengeOffset = prefix.length;
        uint256 originMarkerOffset = challengeOffset + encodedChallenge.length;
        uint256 originOffset = originMarkerOffset + originMarker.length;
        if (clientData.length < originOffset + suffix.length) return false;

        if (!_matches(clientData, 0, prefix)) return false;
        if (!_matches(clientData, challengeOffset, encodedChallenge)) return false;
        if (!_matches(clientData, originMarkerOffset, originMarker)) return false;

        uint256 suffixOffset = clientData.length - suffix.length;
        if (suffixOffset <= originOffset || !_matches(clientData, suffixOffset, suffix)) {
            return false;
        }
        return _sliceHash(clientData, originOffset, suffixOffset - originOffset) == originHash;
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

    function _sliceHash(bytes memory subject, uint256 offset, uint256 length)
        private
        pure
        returns (bytes32 result)
    {
        assembly ("memory-safe") {
            result := keccak256(add(add(subject, 0x20), offset), length)
        }
    }
}
