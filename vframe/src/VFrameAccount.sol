// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {vFrame} from "./vFrame.sol";
import {VFrameTypes as T, IVFrameValidator, IVFrameAccount} from "./IVFrame.sol";
import {VFrameECDSA} from "./VFrameECDSA.sol";

/// @notice Single-owner account for vFrame, using only ordinary Solidity calls.
contract VFrameAccount is IVFrameValidator, IVFrameAccount {
    vFrame public immutable entryPoint;
    address public owner;

    error Unauthorized();
    error InvalidOwner();

    constructor(vFrame entryPoint_, address owner_) {
        if (owner_ == address(0)) revert InvalidOwner();
        entryPoint = entryPoint_;
        owner = owner_;
    }

    function validateFrame(
        T.ValidationContext calldata context,
        T.Frame[] calldata,
        bytes calldata authorization
    ) external view returns (bytes4, uint8) {
        if (
            msg.sender != address(entryPoint)
                || VFrameECDSA.recover(context.transactionHash, authorization) != owner
        ) revert Unauthorized();
        return (T.VALIDATION_MAGIC, context.allowedScope);
    }

    function executeFrame(address target, uint256 value, bytes calldata data) external {
        if (msg.sender != address(entryPoint) || !entryPoint.isExecuting(address(this))) {
            revert Unauthorized();
        }
        // Transparent bounded return/revert data. The target sees this account as msg.sender.
        assembly ("memory-safe") {
            let input := mload(0x40)
            calldatacopy(input, data.offset, data.length)
            let success := call(gas(), target, value, input, data.length, 0, 0)
            let size := returndatasize()
            if gt(size, 2048) { size := 2048 }
            returndatacopy(input, 0, size)
            if iszero(success) { revert(input, size) }
            return(input, size)
        }
    }

    function setOwner(address nextOwner) external {
        if (msg.sender != address(this)) revert Unauthorized();
        if (nextOwner == address(0)) revert InvalidOwner();
        owner = nextOwner;
    }

    function withdrawDeposit(address payable recipient, uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();
        entryPoint.withdrawTo(recipient, amount);
    }

    receive() external payable {}
}
