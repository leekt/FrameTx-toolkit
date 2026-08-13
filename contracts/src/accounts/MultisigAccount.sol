// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title MultisigAccount - a k-of-n multisig smart account for EIP-8141 frame transactions
/// @author taek <leekt216@gmail.com>
/// @notice The whole account is one validation function. There is no `execute()`, no
///         `UserOperation` struct, no signature blob, and no `ecrecover`: the protocol has
///         already verified every secp256k1/P256 signature in the envelope against the
///         canonical transaction signature hash before this code runs. All this contract
///         does is ask *which keys signed* and decide whether it trusts enough of them.
contract MultisigAccount {
    // SIGPARAM `param` selectors (see EIP-8141 "SIGPARAM Instruction (0xb4)").
    uint256 private constant SIG_SIGNER = 0x00; // resolved_signer
    uint256 private constant SIG_SCHEME = 0x01; // 0=ARBITRARY, 1=SECP256K1, 2=P256
    uint256 private constant SIG_MSG = 0x02; // 0 == signed over the canonical sig hash

    uint256 private constant SCHEME_SECP256K1 = 0x01;

    // TXPARAM / FRAMEPARAM selectors.
    uint256 private constant TX_SIG_COUNT = 0x0B; // len(signatures)
    uint256 private constant TX_FRAME_INDEX = 0x0A; // currently executing frame index
    uint256 private constant FRAME_ALLOWED_SCOPE = 0x06; // frame.flags & APPROVE_SCOPE_MASK

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
        uint256 sigCount;
        assembly {
            sigCount := txparam(TX_SIG_COUNT)
        }

        uint256 approvals = 0;
        uint256 prevSigner = 0; // strictly ascending -> no signer can be counted twice

        for (uint256 i = 0; i < sigCount; ++i) {
            // Operand order for SIGPARAM is top-of-stack first: sigparam(signatureIndex, param).
            uint256 scheme;
            assembly {
                scheme := sigparam(i, SIG_SCHEME)
            }
            // Read the scheme BEFORE the signer: asking for resolved_signer of an ARBITRARY
            // entry is an exceptional halt, not a revert, so it would burn the frame's gas
            // and invalidate the whole transaction. Skipping foreign entries (e.g. a
            // paymaster's own signature) keeps this account composable.
            if (scheme != SCHEME_SECP256K1) continue;

            uint256 signedMsg;
            assembly {
                signedMsg := sigparam(i, SIG_MSG)
            }
            // 0 means "signed over compute_sig_hash(tx)", i.e. over THIS transaction: its
            // chain id, nonce, sender and every frame. A non-zero msg is an explicit digest
            // the owner authorized in some other context; counting it would let anyone
            // replay an unrelated owner signature into an arbitrary transaction.
            if (signedMsg != 0) continue;

            uint256 signer;
            assembly {
                signer := sigparam(i, SIG_SIGNER)
            }
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
        // same account usable in both prefixes.
        assembly {
            // approvetx(offset, length, scope) - empty return data region.
            approvetx(0, 0, frameparam(txparam(TX_FRAME_INDEX), FRAME_ALLOWED_SCOPE))
        }
    }
}
