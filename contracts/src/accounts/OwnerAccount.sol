// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {FrameTxLib} from "../frame/FrameTxLib.sol";

/// @title  OwnerAccount
/// @author taek <leekt216@gmail.com>
/// @notice The canonical single-owner EIP-8141 smart account.
/// @dev    The account does NOT verify a signature. The protocol verified every
///         SECP256K1 / P256 entry in `tx.signatures` against the canonical
///         signature hash before frame 0 ran. The account only asks *which key
///         signed* (SIGPARAM) and applies an authorisation policy: "signature 0
///         must come from the owner, over this transaction". That policy is the
///         whole contract.
contract OwnerAccount {
    /// @dev Slot 0. The key authorised to spend from this account.
    address public owner;

    /// @dev setOwner is reachable only through a SENDER frame targeting self.
    error NotSelf();

    constructor(address initialOwner) {
        owner = initialOwner;
    }

    /// @notice VERIFY-frame entry point, called by `ENTRY_POINT` (`address(0xaa)`).
    ///         Frame data is `abi.encodeWithSelector(OwnerAccount.validate.selector)`
    ///         i.e. the 4 bytes `0x6901f668`.
    /// @dev    Runs as a STATICCALL: no SSTORE, no LOG, no state-changing calls are
    ///         possible here, which is why every check below is a pure read. APPROVE
    ///         is the one instruction allowed to mutate transaction state from a
    ///         VERIFY frame. A revert in a VERIFY frame invalidates the WHOLE
    ///         transaction (and unrolls any APPROVE), so `revert(0, 0)` is the
    ///         correct and only rejection path -- there is no "return false".
    function validate() external {
        // `sigSigner(0)` is the address the protocol already recovered and
        // checked -- a verified fact, not a recovery. An ARBITRARY entry has no
        // resolved signer and halts here, which is a fine outcome: this account
        // only accepts protocol-verified schemes. Checking the scheme explicitly
        // is unnecessary -- a P256 entry resolves to keccak256(qx || qy)[12:],
        // so matching a chosen 20-byte owner with a P256 key is as hard as
        // matching it with a secp256k1 key.
        //
        // `signedThisTx(0)` is `sigMsg(0) == 0`: the entry signed the canonical
        // transaction signature hash rather than some other digest the owner
        // signed at some other time, for some other purpose. Accepting a
        // non-zero `msg` would turn any stray off-chain signature into a blank
        // cheque; this check is the replay protection.
        //
        // A revert in a VERIFY frame invalidates the whole transaction -- there
        // is no "return false".
        if (FrameTxLib.sigSigner(0) != owner || !FrameTxLib.signedThisTx(0)) revert();

        // SCOPE_BOTH: this account both authorises later SENDER frames to act
        // as it, and agrees to pay the transaction's max_cost. The requested
        // scope must be a subset of `frame.flags & 0x3`, so the frame MUST
        // carry flags 0x3; and the protocol only allows flags containing
        // APPROVE_EXECUTION when the frame target is `tx.sender`. Consequence
        // worth internalising: this account can never be tricked into paying
        // for a stranger's transaction, because a frame it does not own cannot
        // legally carry the flags this call requires.
        //
        // APPROVE exits the frame successfully, exactly like RETURN: nothing
        // after this line executes.
        FrameTxLib.approve(FrameTxLib.SCOPE_BOTH);
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
    /// @return signer0    SIGPARAM 0x00, the same value `validate` compares.
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
