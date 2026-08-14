// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";

/// @title SponsoringPaymaster
/// @author taek <leekt216@gmail.com>
/// @notice An EIP-8141 sponsoring paymaster: a third party that pays the gas
///         for someone else's frame transaction.
///
/// This contract is the target of a `pay` frame -- VERIFY mode with
/// flags == 0x1 (APPROVE_PAYMENT only). It must come AFTER the sender's
/// `only_verify` frame, because APPROVE(APPROVE_PAYMENT) reverts unless
/// `sender_approved` is already true. See README.md for the frame table.
///
/// The central idea: the protocol has ALREADY verified every secp256k1/P256
/// signature in `tx.signatures` against the canonical signature hash before any
/// frame runs. So this contract does no ecrecover. It asks SIGPARAM *which key*
/// signed, and decides whether it trusts that key.
contract SponsoringPaymaster {
    /// @notice Can withdraw the sponsorship balance.
    address public immutable owner;

    /// @notice The key whose signature authorises sponsorship.
    /// @dev Immutable, not storage, on purpose: the EIP-8141 public mempool
    ///      validation rules reject a validation-prefix frame that "reads
    ///      storage outside tx.sender", and an immutable is baked into the
    ///      runtime code, so reading it is not an SLOAD. Rotating the key means
    ///      redeploying. See README "Mempool caveats".
    address public immutable sponsorSigner;

    /// @notice Refuse to sponsor a transaction whose TXPARAM(0x06) max cost
    ///         exceeds this, in wei.
    uint256 public immutable maxSponsoredCost;

    error NotOwner();
    error WithdrawFailed();
    /// @dev Sponsor entry must be a protocol-verified secp256k1 signature.
    error BadScheme(uint256 scheme);
    /// @dev The signature at `sigIndex` was not produced by `sponsorSigner`.
    error NotSponsorSigner(address signer);
    /// @dev The entry signs an explicit digest instead of this transaction.
    error NotCanonicalSigHash();
    /// @dev Max cost above the configured cap.
    error CostTooHigh(uint256 maxCost);

    constructor(address sponsorSigner_, uint256 maxSponsoredCost_) payable {
        owner = msg.sender;
        sponsorSigner = sponsorSigner_;
        maxSponsoredCost = maxSponsoredCost_;
    }

    /// @notice Top up the sponsorship balance. APPROVE(APPROVE_PAYMENT) reverts
    ///         if this contract does not hold the full max cost at that moment.
    receive() external payable {}

    function withdraw(address payable to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }

    /// @notice Body of the `pay` frame. Approves payment for the whole
    ///         transaction if `tx.signatures[sigIndex]` is a signature by
    ///         `sponsorSigner` over this transaction's canonical signature hash.
    /// @param sigIndex index into `tx.signatures` of the sponsor's entry. It
    ///        arrives as frame data, which is itself covered by the canonical
    ///        signature hash, so the sponsor's own signature commits to it.
    /// @dev NOT `view`, even though every check below is a pure read: APPROVE
    ///      mutates the transaction-scoped approval context (sets `payer`,
    ///      increments the sender nonce, collects max_cost). Everything before
    ///      it must be read-only, because a VERIFY frame executes as a
    ///      STATICCALL -- no SSTORE, no logs, no state-changing calls -- and a
    ///      VERIFY frame that reverts makes the WHOLE transaction invalid.
    /// @dev Outside a frame transaction this function cannot be abused: TXPARAM
    ///      / SIGPARAM / APPROVE all cause an exceptional halt when the current
    ///      transaction is not a frame transaction.
    function sponsorTransaction(uint256 sigIndex) external {
        // Check the scheme BEFORE asking for the signer: sigSigner of an
        // ARBITRARY entry is an exceptional halt, not a revert, so it would
        // burn the frame's whole gas limit instead of producing this error.
        uint256 scheme = FrameTxLib.sigScheme(sigIndex);
        if (scheme != FrameTxLib.SCHEME_SECP256K1) revert BadScheme(scheme);

        // The protocol already checked this signature against the message
        // below. All we decide is whether we trust the key that produced it.
        address signer = FrameTxLib.sigSigner(sigIndex);
        if (signer != sponsorSigner) revert NotSponsorSigner(signer);

        // `signedThisTx` means the entry signs `compute_sig_hash(tx)` -- this
        // exact transaction, with these frames, this sender and these fees. A
        // non-zero msg is an explicit 32-byte digest, i.e. a signature the
        // sponsor made over something else, which a relayer could staple onto
        // an unrelated transaction. Reject it. (The explicit all-zero digest is
        // invalid at the protocol level, so 0 is unambiguous.)
        if (!FrameTxLib.signedThisTx(sigIndex)) revert NotCanonicalSigHash();

        // Belt and braces: the sig hash already commits to max_fee_per_gas and
        // to every frame's gas_limit, so max_cost is implicitly signed. This
        // cap bounds the damage from a mis-signed or over-generous approval.
        uint256 maxCost = FrameTxLib.maxCost();
        if (maxCost > maxSponsoredCost) revert CostTooHigh(maxCost);

        // SCOPE_PAYMENT, not SCOPE_BOTH: EXECUTION is only legal when
        // resolved_target == tx.sender, and we are not the sender. Also,
        // `frame.flags` for a `pay` frame is 0x1, and APPROVE reverts unless
        // the scope is a subset of `flags & 0x3`.
        //
        // APPROVE exits the frame like RETURN, with empty return data here, so
        // nothing after this line executes.
        FrameTxLib.approve(FrameTxLib.SCOPE_PAYMENT);
    }
}
