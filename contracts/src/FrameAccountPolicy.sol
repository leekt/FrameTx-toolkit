// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FrameAccountPolicy
/// @author taek
/// @notice Authorisation policy for EIP-8141 smart accounts, deliberately free of
/// any frame opcodes so that it can be compiled and tested with stock tooling.
///
/// EIP-8141 splits an account cleanly in two:
///
///  1. The protocol verifies every `SECP256K1`/`P256` signature in the envelope
///     against the canonical signature hash *before* any frame runs. The account
///     never touches elliptic curves.
///  2. The account is left with a policy question: given the set of keys that
///     provably signed, and the frames about to execute, should this transaction
///     be approved?
///
/// (2) is ordinary Solidity. It is where the bugs live, and it is what this
/// library contains. The frame glue that feeds it -- `sigparam` to learn the
/// signers, `frameparam` to inspect the frames, `approvetx` to approve -- is a
/// handful of lines and is exercised against a real EVM in the Go harness.
library FrameAccountPolicy {
    /// @notice A session key may only call allowlisted targets, and may not move value.
    struct SessionKey {
        uint64 validUntil; // unix seconds; 0 means "not a session key"
        bool allowValue; // may the key move ether?
    }

    /// @notice Counts how many of `signers` are distinct members of `owners`.
    /// @dev Duplicate signers are counted once. This matters because an EIP-8141
    /// envelope may carry the same signer in several signature entries, and a
    /// VERIFY frame runs as a STATICCALL, so an account cannot use storage as
    /// scratch space to deduplicate. The O(n*m) scan is intentional: `owners` is
    /// small, and the alternative (requiring sorted input) pushes a correctness
    /// burden onto the caller for no real gain at this size.
    /// @param signers Resolved signers, as reported by the protocol.
    /// @param owners The account's owner set.
    /// @return count Number of distinct owners represented in `signers`.
    function countDistinctOwners(address[] memory signers, address[] memory owners)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i = 0; i < signers.length; i++) {
            // Skip a signer already counted earlier in the list.
            bool seen = false;
            for (uint256 j = 0; j < i; j++) {
                if (signers[j] == signers[i]) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            for (uint256 k = 0; k < owners.length; k++) {
                if (owners[k] == signers[i]) {
                    count++;
                    break;
                }
            }
        }
    }

    /// @notice Whether a set of signers satisfies a k-of-n threshold.
    /// @dev A threshold of zero is rejected: it would approve a transaction that
    /// nobody signed.
    function meetsThreshold(address[] memory signers, address[] memory owners, uint256 threshold)
        internal
        pure
        returns (bool)
    {
        if (threshold == 0) return false;
        return countDistinctOwners(signers, owners) >= threshold;
    }

    /// @notice Whether a session key may authorise a single call.
    /// @param key The session key's terms.
    /// @param nowTs The current block timestamp.
    /// @param target The resolved target of the frame.
    /// @param value The frame's value.
    /// @param allowed The allowlisted targets for this key.
    function sessionKeyAllowsCall(
        SessionKey memory key,
        uint256 nowTs,
        address target,
        uint256 value,
        address[] memory allowed
    ) internal pure returns (bool) {
        // validUntil == 0 means the key was never registered. Checked explicitly
        // rather than relying on the expiry comparison, so that an unregistered
        // key is never authorised by a zero timestamp.
        if (key.validUntil == 0) return false;
        if (nowTs > key.validUntil) return false;
        if (value != 0 && !key.allowValue) return false;
        for (uint256 i = 0; i < allowed.length; i++) {
            if (allowed[i] == target) return true;
        }
        return false;
    }

    /// @notice Extracts the 4-byte selector from the first word of a frame's data.
    /// @dev `framedataload(i, 0)` yields a 32-byte word with the selector in its
    /// most significant bytes, so it must be shifted down by 224 bits. Frames
    /// carrying fewer than 4 bytes of data are zero-extended by the opcode, which
    /// is why `dataLen` is taken separately rather than inferred.
    function selectorOf(bytes32 firstWord, uint256 dataLen) internal pure returns (bytes4) {
        if (dataLen < 4) return bytes4(0);
        return bytes4(firstWord);
    }
}
