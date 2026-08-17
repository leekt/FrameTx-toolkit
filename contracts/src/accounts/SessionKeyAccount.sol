// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";

/// @title SessionKeyAccount
/// @author taek <leekt216@gmail.com>
/// @notice EIP-8141 account whose owner key may do anything, while registered
///         *session keys* may only drive a pre-approved (target, selector) set
///         with zero value, and only until the key's expiry.
///
/// Before this code runs, the protocol has verified every SECP256K1 / P256
/// signature against either `compute_sig_hash(tx)` or its explicit digest. This
/// account never calls `ecrecover`: it asks SIGPARAM which key signed, requires
/// the canonical transaction-hash case, and applies policy.
///
/// The policy for a session key is enforced by cross-frame introspection: the
/// VERIFY frame walks every frame the transaction will execute and rejects the
/// whole transaction unless each SENDER frame is one this session key is
/// allowed to make. See `contracts/docs/05-session-key-account.md` for why
/// walking *every* frame is mandatory.
///
/// Expiry works the same way. TIMESTAMP is banned during validation-prefix
/// execution, so the account cannot compare `block.timestamp` to the key's
/// `validUntil` itself. Instead it requires the transaction to open with an
/// expiry verifier frame -- the one frame the protocol lets read the clock --
/// and checks that frame's deadline does not outlive the key. The protocol
/// reverts the whole transaction once `block.timestamp` passes the deadline,
/// so `deadline <= validUntil` is exactly "this key has not expired".
contract SessionKeyAccount {
    // --------------------------------------------------------------- storage

    address public owner;

    /// @notice Keys that may sign for this account under the restricted
    ///         policy, and the unix time each is valid until. 0 disables.
    mapping(address key => uint64 validUntil) public sessionKeys;

    /// @notice (target, selector) pairs a session key may call. One mapping
    ///         covers both the address allowlist and the selector allowlist.
    mapping(address target => mapping(bytes4 selector => bool allowed)) public allowedCall;

    error NotAuthorized();
    error NoTrustedSignature();
    error FrameNotAllowed(uint256 frameIndex);
    error NothingToApprove();
    /// @dev A session-key transaction must open with an expiry verifier frame.
    error NoExpiryFrame();
    /// @dev The expiry frame's deadline outlives the session key.
    error ExpiryBeyondSessionKey(uint64 deadline, uint64 validUntil);

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

    function setSessionKey(address key, uint64 validUntil) external onlyAdmin {
        sessionKeys[key] = validUntil;
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
        (bool ownerSigned, uint64 sessionValidUntil) = _authorize();
        if (!ownerSigned && sessionValidUntil == 0) revert NoTrustedSignature();

        // Owner: unconditional. Session key: the transaction must be
        // time-bounded within the key's life, and every SENDER frame must be
        // one the key is allowed to make.
        if (!ownerSigned) {
            _checkExpiry(sessionValidUntil);
            _checkSenderFrames();
        }

        // Approve exactly the scope this VERIFY frame's flags permit — 0x1
        // PAYMENT, 0x2 EXECUTION, 0x3 BOTH. Requesting anything not in
        // `flags & 0x3` reverts, so deriving the scope from the frame instead of
        // hardcoding 0x3 lets one account serve both the self-relay layout
        // (flags 0x3) and the paymaster layout (flags 0x2, payment approved by
        // someone else's later VERIFY frame).
        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove(); // APPROVE_NONE always reverts

        // Exits the frame, like RETURN.
        FrameTxLib.approve(scope);
    }

    /// @dev Scans the envelope's signature list for a key this account trusts.
    ///      The protocol already checked the cryptography; we only decide whom
    ///      we recognise. The owner wins wherever it appears in the list, so a
    ///      stray session-key entry cannot downgrade an owner-signed
    ///      transaction into the restricted policy. For session keys the
    ///      longest-lived signer wins; any one valid signature suffices.
    function _authorize() private view returns (bool ownerSigned, uint64 sessionValidUntil) {
        uint256 n = FrameTxLib.signatureCount();
        for (uint256 i = 0; i < n; ++i) {
            // ARBITRARY entries carry no resolved signer — sigSigner on one is
            // an exceptional halt, so filter by scheme first.
            if (FrameTxLib.sigScheme(i) == FrameTxLib.SCHEME_ARBITRARY) continue;

            // msg == 0 means the signature is over compute_sig_hash(tx), which
            // commits to the entire frame list. An explicit 32-byte msg does
            // not, and must never be accepted as authority to grant EXECUTION
            // (see README, "Why every frame is checked").
            if (!FrameTxLib.signedThisTx(i)) continue;

            address s = FrameTxLib.sigSigner(i);
            if (s == owner) return (true, sessionValidUntil);
            uint64 validUntil = sessionKeys[s];
            if (validUntil > sessionValidUntil) sessionValidUntil = validUntil;
        }
    }

    /// @dev Requires the transaction to be provably dead before the session key
    ///      is: frame 0 must be the expiry verifier frame (the protocol admits
    ///      it nowhere else) and its deadline must not exceed `validUntil`.
    ///      Without this an issued session key could be used forever.
    function _checkExpiry(uint64 validUntil) private view {
        if (!FrameTxLib.isExpiryFrame(0)) revert NoExpiryFrame();
        uint64 deadline = FrameTxLib.expiryDeadline(0);
        if (deadline > validUntil) revert ExpiryBeyondSessionKey(deadline, validUntil);
    }

    /// @dev Walks the whole frame list and requires every SENDER frame — i.e.
    ///      every frame that will execute with `caller == tx.sender == this
    ///      account` — to be zero-value and on the allowlist.
    ///      DEFAULT and VERIFY frames are ignored: they do not act on this
    ///      account's behalf and cannot move its funds.
    function _checkSenderFrames() private view {
        uint256 n = FrameTxLib.frameCount();
        for (uint256 i = 0; i < n; ++i) {
            if (FrameTxLib.frameMode(i) != FrameTxLib.MODE_SENDER) continue;

            // Session keys never move ETH.
            if (FrameTxLib.frameValue(i) != 0) revert FrameNotAllowed(i);

            // `frameTarget` is the *resolved* target: a null `frame.target`
            // resolves to tx.sender, so this is never zero-by-omission.
            address target = FrameTxLib.frameTarget(i);

            // Reject data shorter than a selector. FRAMEDATALOAD zero-pads past
            // the end of `data` just like CALLDATALOAD, so without this an empty
            // frame would read as selector 0x00000000.
            if (FrameTxLib.frameDataLength(i) < 4) revert FrameNotAllowed(i);

            // The first word of the frame's data holds the selector left-aligned
            // in its high 4 bytes, exactly like calldata.
            bytes4 selector = bytes4(FrameTxLib.frameDataLoad(i, 0));

            if (!allowedCall[target][selector]) revert FrameNotAllowed(i);
        }
    }
}
