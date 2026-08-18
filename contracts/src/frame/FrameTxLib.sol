// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @title  FrameTxLib
/// @author taek <leekt216@gmail.com>
/// @notice Typed Solidity surface over the pinned EIP-8141/native-SIGDATACOPY
///         opcodes: APPROVE (0xaa), TXPARAM (0xb0), FRAMEDATALOAD (0xb1),
///         FRAMEDATACOPY (0xb2), FRAMEPARAM (0xb3), SIGPARAM (0xb4), and
///         SIGDATACOPY (0xb5).
/// @dev    Requires the patched solc (`--experimental --evm-version @future`);
///         it also exposes the local, non-normative tooling-fixture allocation
///         RECENTROOTREFLOAD (0xb6), TXTRACE (0xb7), TXDIFF (0xb8), and
///         EVENTDATACOPY (0xb9). Fixture TXPARAM selectors live at 0x80-0x84,
///         clear of the normative table; they, mode MODE_POST_TX, recent
///         roots, and trace/diff/event values are supplied by the host; this
///         library does not make them transaction-wire data.
///         Every function requires an active frame context. An absent context,
///         an out-of-bounds index, or another halt case flagged below causes an
///         exceptional halt, not a revert. TXTRACE, TXDIFF, and EVENTDATACOPY
///         additionally require the current fixture frame to have MODE_POST_TX.
///
///         All functions are `internal`, so the library inlines and needs no
///         linking or deployment.
library FrameTxLib {
    // ---------------------------------------------------------------- values

    /// Signature schemes (`sigScheme`).
    uint256 internal constant SCHEME_ARBITRARY = 0;
    uint256 internal constant SCHEME_SECP256K1 = 1;
    uint256 internal constant SCHEME_P256 = 2;

    /// Frame modes (`frameMode`). Modes 0-2 are normative EIP-8141;
    /// MODE_POST_TX is a non-normative tooling-fixture mode.
    uint256 internal constant MODE_DEFAULT = 0;
    uint256 internal constant MODE_VERIFY = 1;
    uint256 internal constant MODE_SENDER = 2;
    uint256 internal constant MODE_POST_TX = 3;

    /// Frame statuses (`frameStatus`).
    uint256 internal constant STATUS_FAILED = 0;
    uint256 internal constant STATUS_SUCCESS = 1;
    uint256 internal constant STATUS_SKIPPED = 2;

    /// APPROVE scopes (`approve`, `frameAllowedScope`).
    uint256 internal constant SCOPE_NONE = 0;
    uint256 internal constant SCOPE_PAYMENT = 1;
    uint256 internal constant SCOPE_EXECUTION = 2;
    uint256 internal constant SCOPE_BOTH = 3;

    /// The expiry verifier predeploy (`EXPIRY_VERIFIER`). A VERIFY frame
    /// targeting it carries an 8-byte big-endian deadline and reverts the
    /// transaction once `block.timestamp` passes it.
    address internal constant EXPIRY_VERIFIER = address(0x8141);

    // ----------------------------------------------------- transaction scope

    /// @notice The current transaction type (TXPARAM 0x00).
    function txType() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x00)
        }
    }

    /// @notice The scalar wire nonce under normative EIP-8141 (TXPARAM 0x01).
    ///         A non-normative tooling fixture instead supplies this field as
    ///         a shared keyed-nonce sequence.
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

    /// @notice State gas remaining in the currently executing frame
    ///         (TXPARAM 0x0C). The toolkit meters the state dimension for the
    ///         charges EIP-8141 itself defines; opcode-level EIP-8037 charges
    ///         are not modeled yet.
    function stateGasLeft() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x0C)
        }
    }

    /// @notice Host-supplied sender legacy nonce in transaction pre-state
    ///         (fixture TXPARAM 0x80), distinct from the fixture interpretation
    ///         of `txNonce()` as a shared sequence. Non-normative.
    function legacyNonce() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x80)
        }
    }

    /// @notice Number of host-supplied nonce keys (fixture TXPARAM 0x81).
    ///         Non-normative; the opcode does not validate their ordering.
    function nonceKeyCount() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x81)
        }
    }

    /// @notice Host-supplied nonce-key-list hash (fixture TXPARAM 0x82).
    ///         Non-normative; the opcode and cheatcode do not derive it.
    function nonceKeysHash() internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := txparam(0x82)
        }
    }

    /// @notice Number of host-supplied recent-root references
    ///         (fixture TXPARAM 0x83). Non-normative and not verified here.
    function recentRootReferenceCount() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x83)
        }
    }

    /// @notice First host-supplied nonce key (fixture TXPARAM 0x84).
    ///         Non-normative; exceptional-halts when the fixture list is empty.
    function firstNonceKey() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(0x84)
        }
    }

    // --------------------------------------- host-supplied recent-root fixture
    // Non-normative. RECENTROOTREFLOAD does not verify roots and halts on an
    // out-of-bounds `referenceIndex`.

    /// @notice A host-supplied recent-root reference's source id
    ///         (RECENTROOTREFLOAD field 0x00).
    function recentRootSourceId(uint256 referenceIndex) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := recentrootrefload(0x00, referenceIndex)
        }
    }

    /// @notice A host-supplied recent-root reference's consensus slot
    ///         (RECENTROOTREFLOAD field 0x01).
    function recentRootSlot(uint256 referenceIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := recentrootrefload(0x01, referenceIndex)
        }
    }

    /// @notice A host-supplied recent-root reference's opaque root
    ///         (RECENTROOTREFLOAD field 0x02).
    function recentRoot(uint256 referenceIndex) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := recentrootrefload(0x02, referenceIndex)
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

    /// @notice The frame's execution gas limit, `limits.execution`
    ///         (FRAMEPARAM 0x01).
    function frameGasLimit(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x01)
        }
    }

    /// @notice The frame's mode (FRAMEPARAM 0x02): normative modes 0-2, or the
    ///         host-supplied non-normative fixture mode MODE_POST_TX.
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

    /// @notice The frame's state gas limit, `limits.state` (FRAMEPARAM 0x09).
    function frameStateGasLimit(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x09)
        }
    }

    /// @notice A PAST frame's receipt `gas_used.execution` (FRAMEPARAM 0x0A).
    ///         Asking about the current or a later frame is an exceptional
    ///         halt, so guard with `currentFrameIndex()`.
    function frameExecutionGasUsed(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x0A)
        }
    }

    /// @notice A PAST frame's receipt `gas_used.state` (FRAMEPARAM 0x0B). A
    ///         later frame's refill may still reduce it. Halts for the current
    ///         or a later frame.
    function frameStateGasUsed(uint256 frameIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, 0x0B)
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

    /// @notice Whether the frame is the expiry verifier frame. The protocol
    ///         admits at most one, only as frame 0, so `isExpiryFrame(0)` is the
    ///         whole question of whether the transaction carries a deadline.
    function isExpiryFrame(uint256 frameIndex) internal view returns (bool) {
        return frameMode(frameIndex) == MODE_VERIFY && frameTarget(frameIndex) == EXPIRY_VERIFIER;
    }

    /// @notice An expiry frame's deadline: its 8-byte big-endian frame data,
    ///         which FRAMEDATALOAD returns left-aligned in the first word. Only
    ///         meaningful when `isExpiryFrame(frameIndex)` holds.
    function expiryDeadline(uint256 frameIndex) internal view returns (uint64) {
        return uint64(uint256(frameDataLoad(frameIndex, 0)) >> 192);
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

    /// @notice `len(signature)` of an ARBITRARY entry's raw bytes
    ///         (SIGPARAM 0x03). Halts for protocol-validated schemes, whose
    ///         raw bytes -- length included -- are not introspectable.
    function sigLength(uint256 signatureIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := sigparam(signatureIndex, 0x03)
        }
    }

    /// @notice A slice of an ARBITRARY entry's raw signature bytes
    ///         (`SIGDATACOPY` 0xB5), with CALLDATACOPY semantics:
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
            sigdatacopy(add(data, 0x20), offset, length, signatureIndex)
        }
    }

    /// @notice An ARBITRARY entry's full raw signature bytes.
    function sigData(uint256 signatureIndex) internal view returns (bytes memory) {
        return sigDataSlice(signatureIndex, 0, sigLength(signatureIndex));
    }

    // ------------------------------ host-supplied POST_TX trace fixture scope
    // Non-normative. Every TXTRACE wrapper reads host-supplied data and
    // exceptional-halts unless the current fixture frame has MODE_POST_TX.
    // Indexed selectors also halt when their global trace index is out of bounds;
    // event topic selectors halt when that topic does not exist.

    /// @notice Number of global balance-diff entries (TXTRACE 0x00).
    function traceBalanceDiffCount() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(0, 0x00)
        }
    }

    /// @notice Number of global storage-diff entries (TXTRACE 0x01).
    function traceStorageDiffCount() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(0, 0x01)
        }
    }

    /// @notice Number of deployed-contract entries (TXTRACE 0x02).
    function traceDeploymentCount() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(0, 0x02)
        }
    }

    /// @notice Account for a global balance-diff entry (TXTRACE 0x03).
    function traceBalanceAccount(uint256 index) internal view returns (address v) {
        assembly ("memory-safe") {
            v := txtrace(index, 0x03)
        }
    }

    /// @notice Host-supplied pre-transaction balance for a global entry
    ///         (TXTRACE 0x04).
    function traceBalanceBefore(uint256 index) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(index, 0x04)
        }
    }

    /// @notice Host-supplied balance for a global entry at the fixture POST_TX
    ///         view (TXTRACE 0x05).
    function traceBalanceAfter(uint256 index) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(index, 0x05)
        }
    }

    /// @notice Account for a global storage-diff entry (TXTRACE 0x06).
    function traceStorageAccount(uint256 index) internal view returns (address v) {
        assembly ("memory-safe") {
            v := txtrace(index, 0x06)
        }
    }

    /// @notice Key for a global storage-diff entry (TXTRACE 0x07).
    function traceStorageKey(uint256 index) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(index, 0x07)
        }
    }

    /// @notice Host-supplied pre-transaction value for a global storage entry
    ///         (TXTRACE 0x08).
    function traceStorageBefore(uint256 index) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(index, 0x08)
        }
    }

    /// @notice Host-supplied value for a global storage entry at the fixture
    ///         POST_TX view (TXTRACE 0x09).
    function traceStorageAfter(uint256 index) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(index, 0x09)
        }
    }

    /// @notice Account for a deployed-contract entry (TXTRACE 0x0A).
    function traceDeployedAccount(uint256 index) internal view returns (address v) {
        assembly ("memory-safe") {
            v := txtrace(index, 0x0A)
        }
    }

    /// @notice Host-supplied current code hash for a deployed-contract entry
    ///         (TXTRACE 0x0B).
    function traceDeployedCodeHash(uint256 index) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := txtrace(index, 0x0B)
        }
    }

    /// @notice Number of events in global emission order (TXTRACE 0x0C).
    function traceEventCount() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(0, 0x0C)
        }
    }

    /// @notice Emitter for an event in global emission order (TXTRACE 0x0D).
    function traceEventEmitter(uint256 eventIndex) internal view returns (address v) {
        assembly ("memory-safe") {
            v := txtrace(eventIndex, 0x0D)
        }
    }

    /// @notice Number of topics on an event (TXTRACE 0x0E).
    function traceEventTopicCount(uint256 eventIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(eventIndex, 0x0E)
        }
    }

    /// @notice Topic 0 on an event (TXTRACE 0x0F).
    function traceEventTopic0(uint256 eventIndex) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := txtrace(eventIndex, 0x0F)
        }
    }

    /// @notice Topic 1 on an event (TXTRACE 0x10).
    function traceEventTopic1(uint256 eventIndex) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := txtrace(eventIndex, 0x10)
        }
    }

    /// @notice Topic 2 on an event (TXTRACE 0x11).
    function traceEventTopic2(uint256 eventIndex) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := txtrace(eventIndex, 0x11)
        }
    }

    /// @notice Topic 3 on an event (TXTRACE 0x12).
    function traceEventTopic3(uint256 eventIndex) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := txtrace(eventIndex, 0x12)
        }
    }

    /// @notice Length of an event's non-indexed data (TXTRACE 0x13).
    function traceEventDataLength(uint256 eventIndex) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(eventIndex, 0x13)
        }
    }

    /// @notice Host-supplied gas pre-charge value (TXTRACE 0x14).
    function traceGasPreCharge() internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txtrace(0, 0x14)
        }
    }

    /// @notice Host-supplied gas-payer account (TXTRACE 0x15).
    function traceGasPayer() internal view returns (address v) {
        assembly ("memory-safe") {
            v := txtrace(0, 0x15)
        }
    }

    // ------------------------------- host-supplied POST_TX diff fixture scope
    // Non-normative. Every TXDIFF wrapper exceptional-halts outside the fixture
    // MODE_POST_TX. Direct selectors 0x00-0x05 access live host state on both
    // supplied-diff hits and misses. Their provisional 100 gas is the warm total;
    // a cold access adds only the applicable EIP-2929 cold premium.

    /// @notice Fixture pre-transaction view of `account[key]` (TXDIFF 0x00).
    function storageValueBefore(address account, uint256 key) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txdiff(0x00, account, key)
        }
    }

    /// @notice Fixture POST_TX view of `account[key]` (TXDIFF 0x01).
    function storageValueAfter(address account, uint256 key) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txdiff(0x01, account, key)
        }
    }

    /// @notice Fixture pre-transaction balance view for `account` (TXDIFF 0x02).
    function accountBalanceBefore(address account) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txdiff(0x02, account, 0)
        }
    }

    /// @notice Fixture POST_TX balance view for `account` (TXDIFF 0x03).
    function accountBalanceAfter(address account) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txdiff(0x03, account, 0)
        }
    }

    /// @notice Fixture pre-transaction code-hash view for `account` (TXDIFF 0x04).
    function accountCodeHashBefore(address account) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := txdiff(0x04, account, 0)
        }
    }

    /// @notice Fixture POST_TX code-hash view for `account` (TXDIFF 0x05).
    function accountCodeHashAfter(address account) internal view returns (bytes32 v) {
        assembly ("memory-safe") {
            v := txdiff(0x05, account, 0)
        }
    }

    /// @notice Number of storage-diff entries for `account` (TXDIFF 0x06).
    function accountStorageDiffCount(address account) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txdiff(0x06, account, 0)
        }
    }

    /// @notice Global TXTRACE storage index at an account-local index
    ///         (TXDIFF 0x07). Halts when the local index is out of bounds.
    function accountStorageDiffIndex(address account, uint256 localIndex)
        internal
        view
        returns (uint256 v)
    {
        assembly ("memory-safe") {
            v := txdiff(0x07, account, localIndex)
        }
    }

    /// @notice Number of events emitted by `account` (TXDIFF 0x08).
    function accountEventCount(address account) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txdiff(0x08, account, 0)
        }
    }

    /// @notice Global TXTRACE event index at an account-local index
    ///         (TXDIFF 0x09). Halts when the local index is out of bounds.
    function accountEventIndex(address account, uint256 localIndex)
        internal
        view
        returns (uint256 v)
    {
        assembly ("memory-safe") {
            v := txdiff(0x09, account, localIndex)
        }
    }

    /// @notice Account change flags (TXDIFF 0x0A): bit 0 nonce, bit 1 balance,
    ///         bit 2 storage and bit 3 code hash.
    function accountDiffFlags(address account) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txdiff(0x0A, account, 0)
        }
    }

    // ------------------------- host-supplied POST_TX event-data fixture scope

    /// @notice A strict slice of a host-supplied fixture event's non-indexed
    ///         data (EVENTDATACOPY 0xB9). Exceptional-halts outside MODE_POST_TX,
    ///         for an invalid event index, or when `dataOffset + length` exceeds
    ///         the source; unlike frame/signature copies, it never zero-fills an
    ///         overrun.
    function eventDataSlice(uint256 eventIndex, uint256 dataOffset, uint256 length)
        internal
        view
        returns (bytes memory data)
    {
        data = new bytes(length);
        assembly ("memory-safe") {
            eventdatacopy(eventIndex, add(data, 0x20), dataOffset, length)
        }
    }

    /// @notice A host-supplied fixture event's full non-indexed data. POST_TX-only.
    function eventData(uint256 eventIndex) internal view returns (bytes memory) {
        return eventDataSlice(eventIndex, 0, traceEventDataLength(eventIndex));
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

    /// @notice APPROVE returning the raw contents of `data` to the frame caller.
    ///         This is RETURN-style data, not ABI encoding of a `bytes` value.
    function approve(uint256 scope, bytes memory data) internal {
        assembly ("memory-safe") {
            approvetx(add(data, 0x20), mload(data), scope)
        }
    }
}
