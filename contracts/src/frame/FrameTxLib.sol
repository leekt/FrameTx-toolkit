// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @title  FrameTxLib
/// @author taek <leekt216@gmail.com>
/// @notice Typed Solidity surface over the EIP-8141 frame transaction opcodes:
///         TXPARAM (0xb0), FRAMEDATALOAD (0xb1), FRAMEDATACOPY (0xb2),
///         FRAMEPARAM (0xb3), SIGPARAM (0xb4) and APPROVE (0xaa).
/// @dev    Requires the patched solc (`--experimental --evm-version @future`);
///         every function here compiles to a frame opcode that only exists
///         inside a frame transaction. Calling any of them from another
///         transaction type is an exceptional halt, not a revert: it burns the
///         frame's remaining gas. The same is true for every out-of-bounds
///         index and the other halt cases flagged below, so validate inputs
///         you do not control before passing them down.
///
///         All functions are `internal`, so the library inlines and needs no
///         linking or deployment.
library FrameTxLib {
    // ---------------------------------------------------------------- values

    /// Signature schemes (`sigScheme`).
    uint256 internal constant SCHEME_ARBITRARY = 0;
    uint256 internal constant SCHEME_SECP256K1 = 1;
    uint256 internal constant SCHEME_P256 = 2;

    /// Frame modes (`frameMode`).
    uint256 internal constant MODE_DEFAULT = 0;
    uint256 internal constant MODE_VERIFY = 1;
    uint256 internal constant MODE_SENDER = 2;

    /// Frame statuses (`frameStatus`).
    uint256 internal constant STATUS_FAILED = 0;
    uint256 internal constant STATUS_SUCCESS = 1;
    uint256 internal constant STATUS_SKIPPED = 2;

    /// APPROVE scopes (`approve`, `frameAllowedScope`).
    uint256 internal constant SCOPE_NONE = 0;
    uint256 internal constant SCOPE_PAYMENT = 1;
    uint256 internal constant SCOPE_EXECUTION = 2;
    uint256 internal constant SCOPE_BOTH = 3;

    // ----------------------------------------------------- transaction scope

    /// @notice The current transaction type (TXPARAM 0x00).
    function txType() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x00)
        }
    }

    /// @notice The transaction nonce (TXPARAM 0x01).
    function txNonce() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x01)
        }
    }

    /// @notice The transaction sender (TXPARAM 0x02). Unlike ORIGIN this is
    ///         defined even while no account has approved yet.
    function txSender() internal view returns (address v) {
        assembly ("memory-safe") {
            v := txparam(0x02)
        }
    }

    /// @notice `max_priority_fee_per_gas` (TXPARAM 0x03).
    function maxPriorityFeePerGas() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x03)
        }
    }

    /// @notice `max_fee_per_gas` (TXPARAM 0x04).
    function maxFeePerGas() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x04)
        }
    }

    /// @notice `max_fee_per_blob_gas` (TXPARAM 0x05).
    function maxFeePerBlobGas() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x05)
        }
    }

    /// @notice The transaction's maximum cost (TXPARAM 0x06): all gas at the
    ///         max fee, blob cost, intrinsic cost and signature verification.
    ///         What the payer must hold, and what APPROVE PAYMENT collects.
    function maxCost() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x06)
        }
    }

    /// @notice `len(blob_versioned_hashes)` (TXPARAM 0x07).
    function blobCount() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x07)
        }
    }

    /// @notice The canonical signature hash (TXPARAM 0x08): the digest every
    ///         protocol-verified signature with an empty `msg` signed. Commits
    ///         to the chain id, nonce, sender, fees and every frame.
    function sigHash() internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := txparam(0x08)
        }
    }

    /// @notice `len(frames)` (TXPARAM 0x09).
    function frameCount() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x09)
        }
    }

    /// @notice The index of the frame executing right now (TXPARAM 0x0A).
    function currentFrameIndex() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x0A)
        }
    }

    /// @notice `len(signatures)` (TXPARAM 0x0B).
    function signatureCount() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x0B)
        }
    }

    // ----------------------------------------------------------- frame scope
    // FRAMEPARAM halts on an out-of-bounds `frameIndex`.

    /// @notice The frame's resolved target (FRAMEPARAM 0x00). A null target in
    ///         the envelope resolves to the sender before execution.
    function frameTarget(uint256 frameIndex) internal view returns (address v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x00)
        }
    }

    /// @notice The frame's gas limit (FRAMEPARAM 0x01).
    function frameGasLimit(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x01)
        }
    }

    /// @notice The frame's mode (FRAMEPARAM 0x02): one of the MODE_* values.
    function frameMode(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x02)
        }
    }

    /// @notice The frame's raw flags (FRAMEPARAM 0x03).
    function frameFlags(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x03)
        }
    }

    /// @notice `len(data)` of the frame's input (FRAMEPARAM 0x04).
    function frameDataLength(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x04)
        }
    }

    /// @notice A PAST frame's status (FRAMEPARAM 0x05): one of the STATUS_*
    ///         values. Asking about the current or a later frame is an
    ///         exceptional halt, so guard with `currentFrameIndex()`.
    function frameStatus(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x05)
        }
    }

    /// @notice The scopes the frame allows APPROVE to grant (FRAMEPARAM 0x06):
    ///         `flags & 0x3`, one of the SCOPE_* values.
    function frameAllowedScope(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x06)
        }
    }

    /// @notice Whether the frame belongs to an atomic batch (FRAMEPARAM 0x07).
    function frameIsAtomicBatch(uint256 frameIndex) internal view returns (bool v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x07)
        }
    }

    /// @notice The frame's value (FRAMEPARAM 0x08).
    function frameValue(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x08)
        }
    }

    /// @notice One word of a frame's input data (FRAMEDATALOAD), CALLDATALOAD
    ///         semantics: bytes past the end read as zero.
    function frameDataLoad(uint256 frameIndex, uint256 offset) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := framedataload(offset, frameIndex)
        }
    }

    /// @notice A slice of a frame's input data (FRAMEDATACOPY), CALLDATACOPY
    ///         semantics: bytes past the end are zero-filled, no bounds check.
    function frameDataSlice(uint256 frameIndex, uint256 offset, uint256 length)
        internal
        view
        returns (bytes memory data)
    {
        data = new bytes(length);
        assembly ("memory-safe") {
            framedatacopy(add(data, 0x20), offset, length, frameIndex)
        }
    }

    /// @notice A frame's full input data.
    function frameData(uint256 frameIndex) internal view returns (bytes memory) {
        return frameDataSlice(frameIndex, 0, frameDataLength(frameIndex));
    }

    // ------------------------------------------------------- signature scope
    // SIGPARAM halts on an out-of-bounds `signatureIndex`.

    /// @notice The signer the protocol recovered and verified (SIGPARAM 0x00).
    ///         A verified fact, not a recovery: no ecrecover here. Halts for an
    ///         ARBITRARY entry, which has no protocol signer -- check
    ///         `sigScheme` first when the entry is not under your control.
    function sigSigner(uint256 signatureIndex) internal view returns (address v) {
        assembly ("memory-safe") {
            v := sigparam(signatureIndex, 0x00)
        }
    }

    /// @notice The entry's signature scheme (SIGPARAM 0x01): SCHEME_*.
    function sigScheme(uint256 signatureIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := sigparam(signatureIndex, 0x01)
        }
    }

    /// @notice The entry's `msg` field (SIGPARAM 0x02). Zero means the entry
    ///         signed the canonical signature hash -- this transaction. Any
    ///         other value is a digest signed in some other context; counting
    ///         it as approval of this transaction is a replay hole.
    function sigMsg(uint256 signatureIndex) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := sigparam(signatureIndex, 0x02)
        }
    }

    /// @notice Whether the entry signed THIS transaction (`sigMsg == 0`).
    function signedThisTx(uint256 signatureIndex) internal view returns (bool) {
        return sigMsg(signatureIndex) == bytes32(0);
    }

    /// @notice `len(signature)` of the entry's raw bytes (SIGPARAM 0x03).
    function sigLength(uint256 signatureIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := sigparam(signatureIndex, 0x03)
        }
    }

    /// @notice A slice of an ARBITRARY entry's raw signature bytes (SIGPARAM
    ///         0x04 via the `sigdatacopy` builtin), CALLDATACOPY semantics:
    ///         bytes past the end are zero-filled, no bounds check. Halts if
    ///         the entry's scheme is not ARBITRARY -- protocol-verified schemes
    ///         keep their bytes opaque to allow future aggregation.
    function sigDataSlice(uint256 signatureIndex, uint256 offset, uint256 length)
        internal
        view
        returns (bytes memory data)
    {
        data = new bytes(length);
        assembly ("memory-safe") {
            sigdatacopy(signatureIndex, add(data, 0x20), offset, length)
        }
    }

    /// @notice An ARBITRARY entry's full raw signature bytes.
    function sigData(uint256 signatureIndex) internal view returns (bytes memory) {
        return sigDataSlice(signatureIndex, 0, sigLength(signatureIndex));
    }

    // ---------------------------------------------------------------- approve

    /// @notice APPROVE with no return data. Grants `scope` (a SCOPE_* value)
    ///         and EXITS THE FRAME successfully, like RETURN: nothing after
    ///         this call executes. Reverts if `scope` is not a subset of the
    ///         frame's allowed scope, or if the frame is not entitled to the
    ///         grant (EXECUTION requires the frame target to be the sender;
    ///         PAYMENT requires the payer to cover `maxCost`).
    function approve(uint256 scope) internal {
        assembly ("memory-safe") {
            approvetx(0, 0, scope)
        }
    }

    /// @notice APPROVE returning `data` to the caller of the frame, for
    ///         verifiers whose caller expects return data.
    function approve(uint256 scope, bytes memory data) internal {
        assembly ("memory-safe") {
            approvetx(add(data, 0x20), mload(data), scope)
        }
    }
}
