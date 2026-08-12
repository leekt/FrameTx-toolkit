// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @title SessionKeyAccount
/// @author taek <leekt216@gmail.com>
/// @notice EIP-8141 account whose owner key may do anything, while registered
///         *session keys* may only drive a pre-approved (target, selector) set
///         with zero value.
///
/// The protocol has already verified every SECP256K1 / P256 signature in the
/// envelope against `compute_sig_hash(tx)` before this code runs. So this
/// account never calls `ecrecover`: it asks SIGPARAM *which key signed* and
/// decides whether it trusts that key. All it adds is policy.
///
/// The policy for a session key is enforced by cross-frame introspection: the
/// VERIFY frame walks every frame the transaction will execute and rejects the
/// whole transaction unless each SENDER frame is one this session key is
/// allowed to make. See README.md for why walking *every* frame is mandatory.
contract SessionKeyAccount {
    // ---------------------------------------------------------------- config

    /// @dev Signature schemes (EIP-8141 "Transaction Signatures").
    uint256 private constant SCHEME_ARBITRARY = 0x0;

    /// @dev Frame modes.
    uint256 private constant MODE_SENDER = 0x2;

    /// @dev TXPARAM params.
    uint256 private constant TX_FRAME_COUNT = 0x09;
    uint256 private constant TX_CURRENT_FRAME = 0x0A;
    uint256 private constant TX_SIG_COUNT = 0x0B;

    /// @dev FRAMEPARAM params.
    uint256 private constant FRAME_TARGET = 0x00; // resolved_target
    uint256 private constant FRAME_MODE = 0x02;
    uint256 private constant FRAME_DATA_LEN = 0x04;
    uint256 private constant FRAME_ALLOWED_SCOPE = 0x06; // flags & 0x3
    uint256 private constant FRAME_VALUE = 0x08;

    /// @dev SIGPARAM params.
    uint256 private constant SIG_SIGNER = 0x00; // resolved_signer
    uint256 private constant SIG_SCHEME = 0x01;
    uint256 private constant SIG_MSG = 0x02;

    // --------------------------------------------------------------- storage

    address public owner;

    /// @notice Keys that may sign for this account under the restricted policy.
    mapping(address key => bool enabled) public sessionKeys;

    /// @notice (target, selector) pairs a session key may call. One mapping
    ///         covers both the address allowlist and the selector allowlist.
    mapping(address target => mapping(bytes4 selector => bool allowed)) public allowedCall;

    error NotAuthorized();
    error NoTrustedSignature();
    error FrameNotAllowed(uint256 frameIndex);
    error NothingToApprove();

    /// @dev Admin calls arrive either as a plain call from the owner key, or as
    ///      a SENDER frame targeting this account, whose `caller` is `tx.sender`
    ///      — i.e. this contract's own address.
    modifier onlyAdmin() {
        if (msg.sender != owner && msg.sender != address(this)) revert NotAuthorized();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function setSessionKey(address key, bool enabled) external onlyAdmin {
        sessionKeys[key] = enabled;
    }

    function setAllowedCall(address target, bytes4 selector, bool allowed) external onlyAdmin {
        allowedCall[target][selector] = allowed;
    }

    // ------------------------------------------------------------ validation

    /// @notice Target of the transaction's VERIFY frame.
    /// @dev Cannot be `view`: APPROVE mutates the transaction-scoped approval
    ///      context (and, for PAYMENT, the nonce and balances). Everything
    ///      *before* the APPROVE must be read-only regardless, because a VERIFY
    ///      frame executes as a STATICCALL — no SSTORE, no logs, no
    ///      state-changing calls. Only APPROVE is exempt.
    ///      Reverting here makes the whole transaction invalid.
    function validate() external {
        (bool ownerSigned, bool sessionSigned) = _authorize();
        if (!ownerSigned && !sessionSigned) revert NoTrustedSignature();

        // Owner: unconditional. Session key: every SENDER frame must be one the
        // key is allowed to make.
        if (!ownerSigned) _checkSenderFrames();

        // Approve exactly the scope this VERIFY frame's flags permit — 0x1
        // PAYMENT, 0x2 EXECUTION, 0x3 BOTH. Requesting anything not in
        // `flags & 0x3` reverts, so deriving the scope from the frame instead of
        // hardcoding 0x3 lets one account serve both the self-relay layout
        // (flags 0x3) and the paymaster layout (flags 0x2, payment approved by
        // someone else's later VERIFY frame).
        uint256 scope = _frameParam(_txParam(TX_CURRENT_FRAME), FRAME_ALLOWED_SCOPE);
        if (scope == 0) revert NothingToApprove(); // APPROVE_NONE always reverts

        assembly ("memory-safe") {
            // approvetx(offset, length, scope): offset/length are a RETURN-style
            // return-data region; empty here. Exits the frame.
            approvetx(0, 0, scope)
        }
    }

    /// @dev Scans the envelope's signature list for a key this account trusts.
    ///      The protocol already checked the cryptography; we only decide whom
    ///      we recognise. The owner wins wherever it appears in the list, so a
    ///      stray session-key entry cannot downgrade an owner-signed
    ///      transaction into the restricted policy.
    function _authorize() private view returns (bool ownerSigned, bool sessionSigned) {
        uint256 n = _txParam(TX_SIG_COUNT);
        for (uint256 i = 0; i < n; ++i) {
            // ARBITRARY entries carry no resolved signer — SIGPARAM(i, 0x00) on
            // one is an exceptional halt, so filter by scheme first.
            if (_sigParam(i, SIG_SCHEME) == SCHEME_ARBITRARY) continue;

            // msg == 0 means the signature is over compute_sig_hash(tx), which
            // commits to the entire frame list. An explicit 32-byte msg does
            // not, and must never be accepted as authority to grant EXECUTION
            // (see README, "Why every frame is checked").
            if (_sigParam(i, SIG_MSG) != 0) continue;

            address s = address(uint160(_sigParam(i, SIG_SIGNER)));
            if (s == owner) return (true, sessionSigned);
            if (sessionKeys[s]) sessionSigned = true;
        }
    }

    /// @dev Walks the whole frame list and requires every SENDER frame — i.e.
    ///      every frame that will execute with `caller == tx.sender == this
    ///      account` — to be zero-value and on the allowlist.
    ///      DEFAULT and VERIFY frames are ignored: they do not act on this
    ///      account's behalf and cannot move its funds.
    function _checkSenderFrames() private view {
        uint256 n = _txParam(TX_FRAME_COUNT);
        for (uint256 i = 0; i < n; ++i) {
            if (_frameParam(i, FRAME_MODE) != MODE_SENDER) continue;

            // Session keys never move ETH.
            if (_frameParam(i, FRAME_VALUE) != 0) revert FrameNotAllowed(i);

            // FRAMEPARAM 0x00 is the *resolved* target: a null `frame.target`
            // resolves to tx.sender, so this is never zero-by-omission.
            address target = address(uint160(_frameParam(i, FRAME_TARGET)));

            // Reject data shorter than a selector. FRAMEDATALOAD zero-pads past
            // the end of `data` just like CALLDATALOAD, so without this an empty
            // frame would read as selector 0x00000000.
            if (_frameParam(i, FRAME_DATA_LEN) < 4) revert FrameNotAllowed(i);

            // The first word of the frame's data holds the selector left-aligned
            // in its high 4 bytes, exactly like calldata.
            bytes4 selector = bytes4(uint32(_frameDataLoad(0, i) >> 224));

            if (!allowedCall[target][selector]) revert FrameNotAllowed(i);
        }
    }

    // ------------------------------------------------- introspection wrappers
    // These are `view`, not `pure`: they read transaction context. Operand order
    // below is stack order, top first — the first Yul argument is the topmost
    // stack item.

    function _txParam(uint256 param) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := txparam(param)
        }
    }

    /// @dev FRAMEPARAM stack: frameIndex on top, param below it.
    function _frameParam(uint256 frameIndex, uint256 param) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := frameparam(frameIndex, param)
        }
    }

    /// @dev SIGPARAM stack: signatureIndex on top, param below it.
    function _sigParam(uint256 sigIndex, uint256 param) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := sigparam(sigIndex, param)
        }
    }

    /// @dev FRAMEDATALOAD stack: offset on top, frameIndex below it — the
    ///      opposite nesting from FRAMEPARAM/SIGPARAM. It mirrors CALLDATALOAD
    ///      with the frame index appended underneath.
    function _frameDataLoad(uint256 offset, uint256 frameIndex) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := framedataload(offset, frameIndex)
        }
    }
}
