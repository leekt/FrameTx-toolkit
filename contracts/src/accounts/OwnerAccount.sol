// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {IFrameAccount} from "./IFrameAccount.sol";

/// @title  OwnerAccount
/// @author taek <leekt216@gmail.com>
/// @notice The canonical single-owner EIP-8141 smart account.
/// @dev    The account does NOT verify a signature. Before frame 0, the protocol
///         verified every native entry (SECP256K1 or P256) against either the
///         canonical transaction hash or its explicit digest. Signed VERIFY-frame
///         calldata selects the signature
///         entry this account should inspect; that entry must come from the owner
///         over this transaction.
contract OwnerAccount is IFrameAccount {
    /// @dev Slot 0. The key authorised to spend from this account.
    address public owner;

    /// @dev setOwner is reachable only through a SENDER frame targeting self.
    error NotSelf();
    error NoTrustedSignature();
    error NothingToApprove();

    constructor(address initialOwner) {
        owner = initialOwner;
    }

    /// @notice VERIFY-frame entry point, called by `ENTRY_POINT` (`address(0xaa)`).
    /// @param signatureIndex Entry in `tx.signatures` selected by the
    ///        transaction builder for this account's policy.
    /// @dev    Runs as a STATICCALL: no SSTORE, no LOG, no state-changing calls are
    ///         possible here, which is why every check below is a pure read. APPROVE
    ///         is the one instruction allowed to mutate transaction state from a
    ///         VERIFY frame. A revert in a VERIFY frame invalidates the WHOLE
    ///         transaction (and unrolls any APPROVE), so a revert is the
    ///         rejection path -- there is no "return false".
    function validate(uint256 signatureIndex) external override {
        // Zero is the EVM-visible marker for the canonical transaction hash.
        // An explicit digest does not authorize this frame list.
        if (!FrameTxLib.signedThisTx(signatureIndex)) revert NoTrustedSignature();
        // The protocol already validated whichever native scheme produced this
        // address. ARBITRARY has no resolved signer, so this read fails closed.
        if (FrameTxLib.sigSigner(signatureIndex) != owner) revert NoTrustedSignature();

        // Use the scope named by this frame: BOTH for self relay, EXECUTION when
        // a paymaster pays, or PAYMENT when this account pays for another sender.
        // APPROVE enforces the target/sender and subset rules for each case.
        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
        FrameTxLib.approve(scope);
    }

    /// @notice Read-only tour of the introspection surface. Not used by `validate`;
    ///         it exists so you can see what an account can learn about its own
    ///         transaction. Calling it outside a frame transaction is an
    ///         exceptional halt -- these instructions simply do not exist there.
    /// @return sigHash    TXPARAM 0x08, the canonical signature hash: the digest
    ///                    every empty-`msg` signature in the envelope signed.
    /// @return frameIndex TXPARAM 0x0A, the index of the frame executing now.
    /// @return flags      FRAMEPARAM 0x03 for that frame; `flags & 0x3` is the
    ///                    approval scope APPROVE is allowed to request.
    /// @return mode       FRAMEPARAM 0x02: 0 = DEFAULT, 1 = VERIFY, 2 = SENDER.
    /// @return signer0    SIGPARAM 0x00 for envelope index zero. `validate`
    ///                    instead inspects the one index supplied in its calldata.
    function frameContext()
        external
        view
        returns (bytes32 sigHash, uint256 frameIndex, uint256 flags, uint256 mode, address signer0)
    {
        sigHash = FrameTxLib.sigHash();
        frameIndex = FrameTxLib.currentFrameIndex();
        flags = FrameTxLib.frameFlags(frameIndex);
        mode = FrameTxLib.frameMode(frameIndex);
        signer0 = FrameTxLib.sigSigner(0);
    }

    /// @notice Rotate the owner.
    /// @dev    Reachable only from a SENDER-mode frame whose target is this
    ///         account: in SENDER mode the protocol sets the caller to `tx.sender`,
    ///         which for this account's own transactions is this account. So the
    ///         account calls itself with no proxy, no executor, and no `execute()`
    ///         wrapper.
    function setOwner(address newOwner) external {
        if (msg.sender != address(this)) revert NotSelf();
        owner = newOwner;
    }

    /// @dev The account must be able to hold ETH: APPROVE_PAYMENT reverts unless
    ///      the payer's balance covers `max_cost`.
    receive() external payable {}
}
