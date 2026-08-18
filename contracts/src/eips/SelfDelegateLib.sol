// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @title  SelfDelegateLib
/// @author taek <leekt216@gmail.com>
/// @notice Typed Solidity surface over the EIP-7851 SETSELFDELEGATE opcode
///         (toolkit-local 0xf7; upstream leaves the byte TBD). Delegated
///         wallet code calls it to rewrite its own indicator to
///         `0xef0101 ++ target`, permanently disabling residual ECDSA
///         authority while keeping code-controlled redelegation.
/// @dev    Requires the patched solc (`--experimental --evm-version @future`).
///         The opcode executes only where EIP-7851 is enabled (Anvil
///         `--enable-eip7851` on the Ethereum profile); elsewhere it halts
///         exceptionally. The read helpers are plain EVM code and inspect the
///         raw 23-byte delegation designator that EXTCODECOPY exposes.
library SelfDelegateLib {
    /// EIP-7702 delegation designator prefix: ECDSA authority retained.
    bytes3 internal constant DESIGNATOR_ECDSA = 0xef0100;

    /// EIP-7851 delegation designator prefix: ECDSA authority disabled.
    bytes3 internal constant DESIGNATOR_DISABLED = 0xef0101;

    /// @notice Rewrites the calling account's own delegation indicator to
    ///         `0xef0101 ++ target`. Returns true only when the account's raw
    ///         code was already a 23-byte `0xef0100`/`0xef0101` indicator and
    ///         `target` is non-zero; otherwise no state changes and false is
    ///         returned. Halts in a static context.
    function setSelfDelegate(address target) internal returns (bool ok) {
        assembly ("memory-safe") {
            ok := setselfdelegate(target)
        }
    }

    /// @notice Parses `account`'s raw code as a delegation indicator.
    /// @return isDelegation  the code is exactly 23 bytes with a known prefix
    /// @return ecdsaDisabled the prefix is `0xef0101`
    /// @return target        the delegate address (zero unless isDelegation)
    function delegation(address account) internal view returns (bool isDelegation, bool ecdsaDisabled, address target) {
        uint256 size;
        bytes32 word;
        assembly ("memory-safe") {
            size := extcodesize(account)
            let ptr := mload(0x40)
            mstore(ptr, 0)
            extcodecopy(account, ptr, 0, 23)
            word := mload(ptr)
        }
        if (size != 23) return (false, false, address(0));
        // The 23 code bytes sit left-aligned in `word`.
        uint256 v = uint256(word) >> 72;
        uint24 prefix = uint24(v >> 160);
        if (prefix != uint24(DESIGNATOR_ECDSA) && prefix != uint24(DESIGNATOR_DISABLED)) {
            return (false, false, address(0));
        }
        return (true, prefix == uint24(DESIGNATOR_DISABLED), address(uint160(v)));
    }

    /// @notice Whether `account` carries an `0xef0101` indicator, i.e. its
    ///         residual ECDSA authority is disabled.
    function isEcdsaDisabled(address account) internal view returns (bool) {
        (, bool disabled,) = delegation(account);
        return disabled;
    }
}
