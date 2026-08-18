// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @title  SetDelegateLib
/// @author taek <leekt216@gmail.com>
/// @notice Typed Solidity surface over the EIP-7819 SETDELEGATE opcode (0xf6),
///         which installs an EIP-7702 delegation indicator
///         (`0xef0100 ++ target`) at `keccak256(0xef0100 ++ caller ++ salt)[12:]`
///         and returns that location. A zero target clears the indicator; the
///         account's nonce stays at least one so it never returns to empty.
/// @dev    Requires the patched solc (`--experimental --evm-version @future`).
///         The opcode executes only where EIP-7819 is enabled (Anvil
///         `--enable-eip7819` on Prague-or-later); elsewhere it halts
///         exceptionally. `computeDelegateAddress` is plain EVM code and works
///         everywhere.
library SetDelegateLib {
    /// The EIP-7702 delegation designator prefix, also the address-derivation
    /// domain separator.
    bytes3 internal constant DESIGNATOR = 0xef0100;

    /// @notice Installs (or updates) the delegation indicator for `salt` to
    ///         `target` and returns its address. The location is derived from
    ///         the calling contract, so only the same caller can update it.
    function setDelegate(bytes32 salt, address target) internal returns (address location) {
        assembly ("memory-safe") {
            location := setdelegate(salt, target)
        }
    }

    /// @notice Clears the delegation indicator for `salt` (zero target). The
    ///         account keeps nonce >= 1 and can be re-delegated later.
    function clearDelegate(bytes32 salt) internal returns (address location) {
        assembly ("memory-safe") {
            location := setdelegate(salt, 0)
        }
    }

    /// @notice The address SETDELEGATE assigns for `deployer` and `salt`:
    ///         `keccak256(0xef0100 ++ deployer ++ salt)[12:]`. The 55-byte
    ///         preimage cannot collide with CREATE or CREATE2 derivations.
    function computeDelegateAddress(address deployer, bytes32 salt) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(DESIGNATOR, deployer, salt)))));
    }
}
