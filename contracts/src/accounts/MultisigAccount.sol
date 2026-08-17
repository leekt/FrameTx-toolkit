// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";

/// @title MultisigAccount - a k-of-n multisig smart account for EIP-8141 frame transactions
/// @author taek <leekt216@gmail.com>
/// @notice The whole account is one validation function. There is no `execute()`, no
///         `UserOperation` struct, no signature blob, and no `ecrecover`: the protocol has
///         already verified every secp256k1/P256 signature against its selected message.
///         This contract admits only entries over the canonical transaction hash, asks
///         *which keys signed*, and decides whether it trusts enough of them.
contract MultisigAccount {
    mapping(address => bool) public isOwner;
    uint256 public threshold;

    constructor(address[] memory owners, uint256 threshold_) {
        require(threshold_ != 0 && threshold_ <= owners.length, "bad threshold");
        for (uint256 i = 0; i < owners.length; ++i) {
            require(owners[i] != address(0) && !isOwner[owners[i]], "bad owner");
            isOwner[owners[i]] = true;
        }
        threshold = threshold_;
    }

    /// @notice Entry point of the VERIFY frame. Counts distinct owner signatures in the
    ///         transaction envelope and approves the transaction once `threshold` is reached.
    /// @dev Cannot be `view`: APPROVE mutates transaction-scoped state (sender_approved /
    ///      payer) and, for the payment scope, moves max_cost out of this account.
    ///
    ///      Everything *before* the APPROVE is deliberately read-only, because a VERIFY frame
    ///      executes as a STATICCALL: no SSTORE, no LOG, no state-changing call. Only APPROVE
    ///      is exempt. That is why dedup below cannot use storage as scratch space (see the
    ///      sorted-signers rule) and why there is no "used signature" bookkeeping anywhere.
    ///
    ///      No msg.sender check is needed. The VERIFY frame's caller is ENTRY_POINT, and
    ///      APPROVE itself reverts unless ADDRESS == resolved_target and the requested scope
    ///      is a subset of frame.flags & 0x3, with APPROVE_EXECUTION additionally requiring
    ///      resolved_target == tx.sender. Anyone may *build* a frame transaction naming this
    ///      account as sender; without k owner signatures over that transaction's canonical
    ///      signature hash it simply never gets approved.
    function validate() external {
        uint256 sigCount = FrameTxLib.signatureCount();

        uint256 approvals = 0;
        uint256 prevSigner = 0; // strictly ascending -> no signer can be counted twice

        for (uint256 i = 0; i < sigCount; ++i) {
            // Read the scheme BEFORE the signer: asking for resolved_signer of an ARBITRARY
            // entry is an exceptional halt, not a revert, so it would burn the frame's gas
            // and invalidate the whole transaction. Skipping foreign entries (e.g. a
            // paymaster's own signature) keeps this account composable.
            if (FrameTxLib.sigScheme(i) != FrameTxLib.SCHEME_SECP256K1) continue;

            // `signedThisTx` is `sigMsg(i) == 0`: signed over compute_sig_hash(tx), i.e. over
            // THIS transaction: its chain id, nonce, sender and every frame. A non-zero msg
            // is an explicit digest the owner authorized in some other context; counting it
            // would let anyone replay an unrelated owner signature into an arbitrary
            // transaction.
            if (!FrameTxLib.signedThisTx(i)) continue;

            uint256 signer = uint160(FrameTxLib.sigSigner(i));
            if (!isOwner[address(uint160(signer))]) continue;

            // Dedup without scratch space: counted owners must appear in strictly ascending
            // address order. Zero is not an owner, so the first counted signer passes.
            require(signer > prevSigner, "owner sigs not sorted");
            prevSigner = signer;
            unchecked {
                ++approvals;
            }
        }

        require(approvals >= threshold, "threshold not met");

        // Approve exactly what this frame's flags allow: 0x3 for a self-relaying
        // `self_verify` frame, 0x2 for `only_verify` when a paymaster pays. APPROVE reverts
        // on a scope that is not a subset of the flags, so reading the flags back keeps the
        // same account usable in both prefixes. It exits the frame like RETURN.
        FrameTxLib.approve(FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex()));
    }
}
