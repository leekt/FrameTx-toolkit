// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

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
        address currentOwner = owner;

        assembly ("memory-safe") {
            // SIGPARAM stack layout is `signatureIndex` on TOP, `param` below it.
            // Yul pushes its first argument last, so the first argument is the
            // top-of-stack operand: sigparam(signatureIndex, param).

            // param 0x00 -> resolved_signer of signature 0.
            //
            // This is the address the protocol already recovered and checked. We
            // are not recovering anything; we are reading a verified fact. An
            // ARBITRARY entry has no resolved signer and halts here, which is a
            // fine outcome: this account only accepts protocol-verified schemes.
            // Checking `scheme` explicitly is unnecessary -- a P256 entry resolves
            // to keccak256(qx || qy)[12:], so matching a chosen 20-byte owner with
            // a P256 key is as hard as matching it with a secp256k1 key.
            let signer := sigparam(0, 0x00)

            // param 0x02 -> the signature entry's `msg` field.
            //
            // Zero means the entry signed the canonical transaction signature
            // hash, TXPARAM 0x08 (the spec reserves the zero value for exactly
            // this, since the explicit zero digest is invalid). A non-zero `msg`
            // is some other digest the owner signed at some other time, for some
            // other purpose -- accepting it would turn any stray off-chain
            // signature into a blank cheque. This check is what binds the
            // approval to THIS transaction; without it there is no replay
            // protection at all.
            let signedThisTx := iszero(sigparam(0, 0x02))

            if iszero(and(eq(signer, currentOwner), signedThisTx)) { revert(0, 0) }

            // APPROVE stack layout is `offset`, `length`, `scope` from the top, so
            // Yul order is approvetx(offset, length, scope). It exits the frame
            // successfully, exactly like RETURN, with memory [offset, offset+length)
            // as return data -- here, no return data.
            //
            // scope 0x3 = APPROVE_EXECUTION_AND_PAYMENT: this account both
            // authorises later SENDER frames to act as it, and agrees to pay the
            // transaction's max_cost. The requested scope must be a subset of
            // `frame.flags & 0x3`, so the frame MUST carry flags 0x3; and the
            // protocol only allows flags containing APPROVE_EXECUTION when the
            // frame target is `tx.sender`. Consequence worth internalising: this
            // account can never be tricked into paying for a stranger's
            // transaction, because a frame it does not own cannot legally carry
            // the flags this call requires.
            approvetx(0, 0, 3)
        }
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
        assembly ("memory-safe") {
            sigHash := txparam(0x08)
            frameIndex := txparam(0x0a)
            // FRAMEPARAM takes `frameIndex` on top, `param` below:
            // frameparam(frameIndex, param).
            flags := frameparam(frameIndex, 0x03)
            mode := frameparam(frameIndex, 0x02)
            signer0 := sigparam(0, 0x00)
        }
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
