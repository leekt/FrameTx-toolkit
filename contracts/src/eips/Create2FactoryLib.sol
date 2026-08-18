// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title  Create2FactoryLib
/// @author taek <leekt216@gmail.com>
/// @notice Typed surface over the EIP-7997 deterministic CREATE2 factory at
///         `0x4e59b44847b379578588920cA78FbF26c0B4956C`. The factory reads a
///         32-byte salt followed by initcode from calldata, forwards call
///         value, and returns the created address as exactly 20 unpadded
///         bytes; on failure it reverts with empty return data.
/// @dev    Uses no frame opcodes, so it compiles with stock solc and runs on
///         any chain carrying the factory. Anvil installs the exact factory
///         address and runtime by default; Foundry's test EVM injects the
///         same account.
library Create2FactoryLib {
    /// `FACTORY_ADDRESS` (EIP-7997).
    address internal constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// The factory call failed: creation reverted, the salt was already
    /// consumed, or no factory is deployed on this chain.
    error DeploymentFailed();

    /// @notice The address `deploy` produces for `salt` and initcode hashing
    ///         to `initCodeHash`: standard CREATE2 derivation with the
    ///         factory as the creating account.
    function computeAddress(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", FACTORY, salt, initCodeHash)))));
    }

    /// @notice Deploys `initCode` through the factory.
    function deploy(bytes32 salt, bytes memory initCode) internal returns (address) {
        return deploy(salt, initCode, 0);
    }

    /// @notice Deploys `initCode` through the factory, forwarding `value` wei
    ///         to the constructor. Reverts with `DeploymentFailed` when the
    ///         factory call fails; the factory itself surfaces no reason.
    function deploy(bytes32 salt, bytes memory initCode, uint256 value) internal returns (address deployed) {
        (bool ok, bytes memory ret) = FACTORY.call{value: value}(abi.encodePacked(salt, initCode));
        if (!ok || ret.length != 20) revert DeploymentFailed();
        deployed = address(bytes20(ret));
    }
}
