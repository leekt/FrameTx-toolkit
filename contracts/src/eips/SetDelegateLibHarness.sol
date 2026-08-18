// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {SetDelegateLib} from "./SetDelegateLib.sol";

/// @title  SetDelegateLibHarness
/// @author taek <leekt216@gmail.com>
/// @notice Test-only pass-through exposing SetDelegateLib externally so the
///         forge tests can execute the wrappers. Not a factory; carries no
///         policy.
contract SetDelegateLibHarness {
    function setDelegate(bytes32 salt, address target) external returns (address) {
        return SetDelegateLib.setDelegate(salt, target);
    }

    function clearDelegate(bytes32 salt) external returns (address) {
        return SetDelegateLib.clearDelegate(salt);
    }

    function computeDelegateAddress(address deployer, bytes32 salt)
        external
        pure
        returns (address)
    {
        return SetDelegateLib.computeDelegateAddress(deployer, salt);
    }
}
