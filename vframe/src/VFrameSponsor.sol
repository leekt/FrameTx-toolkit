// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {vFrame} from "./vFrame.sol";
import {VFrameTypes as T, IVFrameValidator} from "./IVFrame.sol";
import {VFrameECDSA} from "./VFrameECDSA.sol";

/// @notice Reserves and pays gas from its deposit after its owner approves the entire operation.
contract VFrameSponsor is IVFrameValidator {
    vFrame public immutable entryPoint;
    address public immutable owner;

    error Unauthorized();

    constructor(vFrame entryPoint_, address owner_) {
        if (owner_ == address(0)) revert Unauthorized();
        entryPoint = entryPoint_;
        owner = owner_;
    }

    function validateFrame(
        T.ValidationContext calldata context,
        T.Frame[] calldata,
        bytes calldata authorization
    ) external view returns (bytes4, uint8) {
        if (
            msg.sender != address(entryPoint) || context.allowedScope != T.PAYMENT
                || VFrameECDSA.recover(context.transactionHash, authorization) != owner
        ) revert Unauthorized();
        return (T.VALIDATION_MAGIC, T.PAYMENT);
    }

    function withdrawDeposit(address payable recipient, uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();
        entryPoint.withdrawTo(recipient, amount);
    }
}
