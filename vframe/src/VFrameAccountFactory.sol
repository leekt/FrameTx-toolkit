// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {vFrame} from "./vFrame.sol";
import {VFrameAccount} from "./VFrameAccount.sol";

/// @notice Permissionless, deterministic account deployment, including from DEFAULT frames.
contract VFrameAccountFactory {
    vFrame public immutable entryPoint;

    event AccountCreated(address indexed account, address indexed owner, bytes32 salt);

    constructor(vFrame entryPoint_) {
        require(address(entryPoint_).code.length != 0, "Invalid EntryPoint");
        entryPoint = entryPoint_;
    }

    function createAccount(address owner, bytes32 salt) external returns (VFrameAccount account) {
        address predicted = getAddress(owner, salt);
        if (predicted.code.length != 0) return VFrameAccount(payable(predicted));
        account = new VFrameAccount{salt: salt}(entryPoint, owner);
        emit AccountCreated(address(account), owner, salt);
    }

    function getAddress(address owner, bytes32 salt) public view returns (address) {
        if (owner == address(0)) revert VFrameAccount.InvalidOwner();
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(VFrameAccount).creationCode, abi.encode(entryPoint, owner))
        );
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))
                )
            )
        );
    }
}
