// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {Base64Url} from "../crypto/Base64Url.sol";
import {WebAuthnVerifier} from "../crypto/WebAuthnVerifier.sol";
import {IFrameAccount} from "./IFrameAccount.sol";

/// @dev Retained solely so FrameKernel's original slot-0 public mapping and getter keep their
///      source-level type. The upgraded account never calls legacy formatter code.
interface IFormatter {
    function format(bytes32 txHash, bytes calldata data, uint256 index)
        external
        view
        returns (bytes32);
}

/// @title FrameKernel
/// @notice Multi-authority EIP-8141 account with native secp256k1/P256 and passkey support.
/// @dev Native signatures are verified by the protocol. WebAuthn assertions use an empty-msg
///      ARBITRARY envelope entry, but their cryptography is still P256 and is checked through
///      the protocol's P256VERIFY precompile by `WebAuthnVerifier`.
contract FrameKernel is IFrameAccount {
    uint256 public constant WEB_AUTHN_WITNESS_LENGTH = 224;
    uint256 public constant MAX_ORIGIN_LENGTH = 1024;
    address private constant LEGACY_NATIVE_SENTINEL = address(1);

    struct WebAuthnCredential {
        bytes32 publicKeyX;
        bytes32 publicKeyY;
        bytes32 rpIdHash;
        bytes32 originHash;
        string origin;
        bool requireUserVerification;
        bool enabled;
    }

    /// @dev Slot 0 and the `formatter(address)` getter deliberately preserve the original
    ///      FrameKernel layout. Only the old address(1) native-signer sentinel remains an
    ///      authority. Non-sentinel formatter contracts are never called or treated as signers.
    mapping(address signer => IFormatter legacyFormatter) public formatter;

    /// @notice Scheme-specific native authorities. This prevents a P256-derived address from
    ///         silently authorizing a secp256k1 entry (or the reverse) with the same address.
    mapping(uint256 scheme => mapping(address signer => bool trusted)) public nativeSigner;

    mapping(address signer => WebAuthnCredential credential) private _webAuthnCredentials;

    error OnlySelf();
    error InvalidConfiguration();
    error UnsupportedScheme(uint256 scheme);
    error ExplicitSignatureMessage();
    error NotApproved();
    error InvalidWebAuthnWitness();
    error NothingToApprove();

    event NativeSignerChanged(uint256 indexed scheme, address indexed signer, bool trusted);
    event LegacySignerMigrated(uint256 indexed scheme, address indexed signer, bool trusted);
    event WebAuthnCredentialChanged(address indexed signer, bool enabled);

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /// @param initialScheme Either the native secp256k1 or native P256 scheme.
    /// @param initialSigner Protocol-resolved signer identity for the initial authority.
    constructor(uint256 initialScheme, address initialSigner) {
        _setNativeSigner(initialScheme, initialSigner, true);
    }

    /// @notice Authenticate one selected native signature or WebAuthn assertion.
    function validate(uint256 signatureIndex) external override {
        uint256 scheme = FrameTxLib.sigScheme(signatureIndex);
        if (!FrameTxLib.signedThisTx(signatureIndex)) revert ExplicitSignatureMessage();

        if (scheme == FrameTxLib.SCHEME_SECP256K1 || scheme == FrameTxLib.SCHEME_P256) {
            _validateNative(signatureIndex, scheme);
        } else if (scheme == FrameTxLib.SCHEME_ARBITRARY) {
            _validateWebAuthn(signatureIndex);
        } else {
            revert UnsupportedScheme(scheme);
        }

        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
        FrameTxLib.approve(scope);
    }

    /// @notice Add, rotate, or revoke a protocol-verified native signer.
    function setNativeSigner(uint256 scheme, address signer, bool trusted) external onlySelf {
        _setNativeSigner(scheme, signer, trusted);
    }

    /// @notice Replace a slot-0 legacy authority with one exact native-scheme decision.
    /// @dev Clears either the old address(1) native sentinel or a non-authorizing legacy
    ///      formatter value. Passing `trusted = true` installs authority only for `scheme`.
    function migrateLegacySigner(uint256 scheme, address signer, bool trusted) external onlySelf {
        formatter[signer] = IFormatter(address(0));
        _setNativeSigner(scheme, signer, trusted);
        emit LegacySignerMigrated(scheme, signer, trusted);
    }

    /// @notice Add or replace a WebAuthn P256 credential.
    /// @dev The credential identity is the protocol's P256 signer derivation,
    ///      `keccak256(qx || qy)[12:]`. The exact origin is retained so validation can
    ///      reconstruct canonical client data without accepting challenge-dependent bytes.
    function setWebAuthnCredential(
        bytes32 publicKeyX,
        bytes32 publicKeyY,
        bytes32 rpIdHash,
        string calldata origin,
        bool requireUserVerification
    ) external onlySelf returns (address signer) {
        uint256 originLength = bytes(origin).length;
        if (
            (publicKeyX == bytes32(0) && publicKeyY == bytes32(0)) || rpIdHash == bytes32(0)
                || originLength == 0 || originLength > MAX_ORIGIN_LENGTH
        ) revert InvalidConfiguration();

        signer = signerForP256Key(publicKeyX, publicKeyY);
        _webAuthnCredentials[signer] = WebAuthnCredential({
            publicKeyX: publicKeyX,
            publicKeyY: publicKeyY,
            rpIdHash: rpIdHash,
            originHash: keccak256(bytes(origin)),
            origin: origin,
            requireUserVerification: requireUserVerification,
            enabled: true
        });
        emit WebAuthnCredentialChanged(signer, true);
    }

    /// @notice Revoke a WebAuthn credential by its P256-derived signer identity.
    function removeWebAuthnCredential(address signer) external onlySelf {
        delete _webAuthnCredentials[signer];
        emit WebAuthnCredentialChanged(signer, false);
    }

    function webAuthnCredential(address signer)
        external
        view
        returns (
            bytes32 publicKeyX,
            bytes32 publicKeyY,
            bytes32 rpIdHash,
            bytes32 originHash,
            string memory origin,
            bool requireUserVerification,
            bool enabled
        )
    {
        WebAuthnCredential storage credential = _webAuthnCredentials[signer];
        return (
            credential.publicKeyX,
            credential.publicKeyY,
            credential.rpIdHash,
            credential.originHash,
            credential.origin,
            credential.requireUserVerification,
            credential.enabled
        );
    }

    /// @notice Derive the EIP-8141 signer identity for a P256 public key.
    function signerForP256Key(bytes32 publicKeyX, bytes32 publicKeyY)
        public
        pure
        returns (address signer)
    {
        if (publicKeyX == bytes32(0) && publicKeyY == bytes32(0)) {
            revert InvalidConfiguration();
        }
        signer = address(uint160(uint256(keccak256(abi.encodePacked(publicKeyX, publicKeyY)))));
        if (signer == address(0)) revert InvalidConfiguration();
    }

    function _setNativeSigner(uint256 scheme, address signer, bool trusted) private {
        if (
            (scheme != FrameTxLib.SCHEME_SECP256K1 && scheme != FrameTxLib.SCHEME_P256)
                || signer == address(0)
        ) revert InvalidConfiguration();
        nativeSigner[scheme][signer] = trusted;
        emit NativeSignerChanged(scheme, signer, trusted);
    }

    function _validateNative(uint256 signatureIndex, uint256 scheme) private view {
        address signer = FrameTxLib.sigSigner(signatureIndex);
        bool legacyNativeSigner = address(formatter[signer]) == LEGACY_NATIVE_SENTINEL;
        if (!nativeSigner[scheme][signer] && !legacyNativeSigner) revert NotApproved();
    }

    function _validateWebAuthn(uint256 signatureIndex) private view {
        if (FrameTxLib.sigLength(signatureIndex) != WEB_AUTHN_WITNESS_LENGTH) {
            revert InvalidWebAuthnWitness();
        }

        bytes memory encoded = FrameTxLib.sigData(signatureIndex);
        (address signer, bytes32 r, bytes32 s, bytes memory authenticatorData) =
            abi.decode(encoded, (address, bytes32, bytes32, bytes));

        // Empty-msg ARBITRARY bytes are elided from the canonical transaction hash.
        // Enforce one canonical encoding so alternate padding/offset forms cannot
        // produce multiple transaction encodings for the same authorization.
        if (keccak256(encoded) != keccak256(abi.encode(signer, r, s, authenticatorData))) {
            revert InvalidWebAuthnWitness();
        }

        WebAuthnCredential storage stored = _webAuthnCredentials[signer];
        if (!stored.enabled) revert NotApproved();

        bytes32 challenge = FrameTxLib.sigHash();
        bytes memory clientDataJSON = abi.encodePacked(
            '{"type":"webauthn.get","challenge":"',
            Base64Url.encode32(challenge),
            '","origin":"',
            stored.origin,
            '","crossOrigin":false}'
        );
        bytes memory assertion = abi.encode(r, s, authenticatorData, clientDataJSON);
        WebAuthnVerifier.Credential memory credential = WebAuthnVerifier.Credential({
            publicKeyX: stored.publicKeyX,
            publicKeyY: stored.publicKeyY,
            rpIdHash: stored.rpIdHash,
            originHash: stored.originHash,
            requireUserVerification: stored.requireUserVerification
        });
        if (!WebAuthnVerifier.verify(assertion, challenge, credential)) {
            revert InvalidWebAuthnWitness();
        }
    }

    /// @dev Accounts that approve PAYMENT must accept ordinary ETH funding.
    receive() external payable {}
}
