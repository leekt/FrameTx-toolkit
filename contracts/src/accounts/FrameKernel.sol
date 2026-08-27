// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {P256} from "solady/utils/P256.sol";
import {ExcessivelySafeCall} from "ExcessivelySafeCall/ExcessivelySafeCall.sol";

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {IFormatter} from "../formatters/IFormatter.sol";
import {IFrameAccount} from "./IFrameAccount.sol";

/// @title FrameKernel
/// @notice Modular EIP-8141 account with native signers and formatted P256 authorization.
/// @dev FrameKernel owns authority and P256 verification. A formatter owns no key: it only
///      transforms signed frame data and the canonical transaction hash into the digest that
///      an authorized P256 key signed. This keeps WebAuthn entirely outside the kernel.
contract FrameKernel is IFrameAccount {
    using ExcessivelySafeCall for address;

    uint256 public constant MIN_FORMATTED_P256_PROOF_LENGTH = 192;
    uint256 public constant MAX_FORMATTED_P256_PROOF_LENGTH = 2_048;
    uint256 public constant MAX_FORMATTER_DATA_LENGTH = 2_048;
    address private constant LEGACY_NATIVE_SENTINEL = address(1);

    /// @dev Original FrameKernel slot 0 and getter. A nonzero, non-sentinel formatter marks
    ///      `signer` as an authorized formatted-P256 key. The sentinel retains legacy native
    ///      authority but is never called as a formatter.
    mapping(address signer => IFormatter selectedFormatter) public formatter;

    /// @dev Slot 1. Direct protocol-verified authorities remain scheme-specific.
    mapping(uint256 scheme => mapping(address signer => bool trusted)) public nativeSigner;

    /// @dev Slot 2 is intentionally never reused. A short-lived pre-release revision placed
    ///      embedded credential state at this mapping namespace; leaving the linear slot
    ///      reserved prevents a later variable from aliasing that dormant deployment data.
    bytes32 private __reservedSlot2;

    struct FormattedP256Proof {
        bytes32 r;
        bytes32 s;
        bytes32 publicKeyX;
        bytes32 publicKeyY;
        bytes formatterProof;
    }

    error OnlySelf();
    error InvalidConfiguration();
    error InvalidFrameMode(uint256 mode);
    error UnsupportedScheme(uint256 scheme);
    error ExplicitSignatureMessage();
    error NotApproved();
    error InvalidFormattedP256Proof();
    error FormatterFailed();
    error NothingToApprove();

    event NativeSignerChanged(uint256 indexed scheme, address indexed signer, bool trusted);
    event LegacySignerMigrated(uint256 indexed scheme, address indexed signer, bool trusted);
    event FormatterChanged(address indexed signer, address indexed selectedFormatter);

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /// @param initialScheme SECP256K1/P256 for a direct native authority, or ARBITRARY for
    ///        a formatted P256 authority.
    /// @param initialSigner Protocol P256 signer derivation (`keccak256(qx || qy)[12:]`) for
    ///        a formatted authority, or the protocol-resolved native signer address.
    /// @param initialFormatter Required only for an ARBITRARY/formatted P256 authority.
    constructor(uint256 initialScheme, address initialSigner, IFormatter initialFormatter) {
        if (initialScheme == FrameTxLib.SCHEME_ARBITRARY) {
            if (initialSigner == address(0) || address(initialFormatter) == address(0)) {
                revert InvalidConfiguration();
            }
            _setFormatter(initialSigner, initialFormatter);
        } else {
            if (address(initialFormatter) != address(0)) revert InvalidConfiguration();
            _setNativeSigner(initialScheme, initialSigner, true);
        }
    }

    /// @notice Authenticate a direct protocol-verified secp256k1 or P256 signature.
    function validate(uint256 signatureIndex) external override {
        _requireVerifyFrame();
        uint256 scheme = FrameTxLib.sigScheme(signatureIndex);
        if (scheme != FrameTxLib.SCHEME_SECP256K1 && scheme != FrameTxLib.SCHEME_P256) {
            revert UnsupportedScheme(scheme);
        }
        if (!FrameTxLib.signedThisTx(signatureIndex)) revert ExplicitSignatureMessage();

        address signer = FrameTxLib.sigSigner(signatureIndex);
        bool legacyNativeSigner = address(formatter[signer]) == LEGACY_NATIVE_SENTINEL;
        if (!nativeSigner[scheme][signer] && !legacyNativeSigner) revert NotApproved();
        _approveCurrentScope();
    }

    /// @notice Authenticate a formatter-produced digest with an authorized P256 key.
    /// @dev The signature entry must be an empty-msg ARBITRARY entry containing exactly
    ///      `abi.encode(r, s, qx, qy, formatterProof)`. Its challenge-dependent bytes are
    ///      therefore elided from `sigHash`, while `formatterData` is frame calldata and is
    ///      committed by `sigHash`. The selected formatter has no authority by itself;
    ///      FrameKernel derives and authorizes the key, then performs the P256 verification.
    function validate(uint256 signatureIndex, bytes calldata formatterData) external {
        _requireVerifyFrame();
        uint256 scheme = FrameTxLib.sigScheme(signatureIndex);
        if (scheme != FrameTxLib.SCHEME_ARBITRARY) revert UnsupportedScheme(scheme);
        if (!FrameTxLib.signedThisTx(signatureIndex)) revert ExplicitSignatureMessage();
        if (
            formatterData.length == 0 || formatterData.length > MAX_FORMATTER_DATA_LENGTH
                || FrameTxLib.sigLength(signatureIndex) < MIN_FORMATTED_P256_PROOF_LENGTH
                || FrameTxLib.sigLength(signatureIndex) > MAX_FORMATTED_P256_PROOF_LENGTH
        ) revert InvalidFormattedP256Proof();

        FormattedP256Proof memory proof = _decodeProof(FrameTxLib.sigData(signatureIndex));
        address signer = signerForP256Key(proof.publicKeyX, proof.publicKeyY);
        IFormatter selectedFormatter = formatter[signer];
        address formatterAddress = address(selectedFormatter);
        if (
            formatterAddress == address(0) || formatterAddress == LEGACY_NATIVE_SENTINEL
                || formatterAddress.code.length == 0
        ) revert NotApproved();

        bytes32 messageHash =
            _format(formatterAddress, signatureIndex, formatterData, proof.formatterProof);
        if (!P256.verifySignature(
                messageHash, proof.r, proof.s, proof.publicKeyX, proof.publicKeyY
            )) {
            revert InvalidFormattedP256Proof();
        }
        _approveCurrentScope();
    }

    /// @notice Add, rotate, or revoke a direct protocol-verified native signer.
    function setNativeSigner(uint256 scheme, address signer, bool trusted) external onlySelf {
        _setNativeSigner(scheme, signer, trusted);
    }

    /// @notice Install, replace, or revoke the formatter for one P256-derived key.
    /// @dev Setting a formatter authorizes only formatted P256 proofs from that exact key.
    function setFormatter(address signer, IFormatter selectedFormatter) external onlySelf {
        _setFormatter(signer, selectedFormatter);
    }

    /// @notice Replace a slot-0 legacy authority with one exact native-scheme decision.
    function migrateLegacySigner(uint256 scheme, address signer, bool trusted) external onlySelf {
        formatter[signer] = IFormatter(address(0));
        _setNativeSigner(scheme, signer, trusted);
        emit LegacySignerMigrated(scheme, signer, trusted);
    }

    /// @notice Derive the protocol P256 signer identity for an uncompressed public key.
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

    function _setFormatter(address signer, IFormatter selectedFormatter) private {
        address formatterAddress = address(selectedFormatter);
        if (
            signer == address(0) || formatterAddress == LEGACY_NATIVE_SENTINEL
                || (formatterAddress != address(0) && formatterAddress.code.length == 0)
        ) revert InvalidConfiguration();
        formatter[signer] = selectedFormatter;
        emit FormatterChanged(signer, formatterAddress);
    }

    function _requireVerifyFrame() private view {
        uint256 mode = FrameTxLib.frameMode(FrameTxLib.currentFrameIndex());
        if (mode != FrameTxLib.MODE_VERIFY) revert InvalidFrameMode(mode);
    }

    function _format(
        address formatterAddress,
        uint256 signatureIndex,
        bytes calldata formatterData,
        bytes memory formatterProof
    ) private view returns (bytes32 messageHash) {
        // Copy at most 33 bytes. Exact ABI output is 32; 33 also detects every larger return
        // without allowing a hostile formatter to force unbounded returndata allocation.
        (bool success, bytes memory result) = formatterAddress.excessivelySafeStaticCall(
            gasleft(),
            33,
            abi.encodeCall(
                IFormatter.format,
                (FrameTxLib.sigHash(), formatterData, formatterProof, signatureIndex)
            )
        );
        if (!success || result.length != 32) revert FormatterFailed();
        assembly ("memory-safe") {
            messageHash := mload(add(result, 0x20))
        }
        if (messageHash == bytes32(0)) revert FormatterFailed();
    }

    function _decodeProof(bytes memory encoded)
        private
        pure
        returns (FormattedP256Proof memory proof)
    {
        (proof.r, proof.s, proof.publicKeyX, proof.publicKeyY, proof.formatterProof) =
            abi.decode(encoded, (bytes32, bytes32, bytes32, bytes32, bytes));
        if (
            keccak256(encoded)
                != keccak256(
                    abi.encode(
                        proof.r, proof.s, proof.publicKeyX, proof.publicKeyY, proof.formatterProof
                    )
                )
        ) revert InvalidFormattedP256Proof();
    }

    function _approveCurrentScope() private {
        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
        FrameTxLib.approve(scope);
    }

    /// @dev Accounts that approve PAYMENT must accept ordinary ETH funding.
    receive() external payable {}
}
