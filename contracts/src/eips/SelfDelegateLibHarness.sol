// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {SelfDelegateLib} from "./SelfDelegateLib.sol";

/// @title  SelfDelegateLibHarness
/// @author taek <leekt216@gmail.com>
/// @notice Test-only pass-through exposing SelfDelegateLib externally so the
///         forge tests can execute the wrappers. Not a wallet; carries no
///         policy.
contract SelfDelegateLibHarness {
    function setSelfDelegate(address target) external returns (bool) {
        return SelfDelegateLib.setSelfDelegate(target);
    }

    function delegation(address account) external view returns (bool isDelegation, bool ecdsaDisabled, address target) {
        return SelfDelegateLib.delegation(account);
    }

    function isEcdsaDisabled(address account) external view returns (bool) {
        return SelfDelegateLib.isEcdsaDisabled(account);
    }
}
