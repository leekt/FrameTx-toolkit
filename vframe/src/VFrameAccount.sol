// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {vFrame} from "./vFrame.sol";
import {VFrameTypes as T, IVFrameValidator, IVFrameAccount} from "./IVFrame.sol";

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

    /// @dev The argument encodes a signature index; empty bytes select index zero.
    function validateFrame(bytes calldata data) external returns (bytes4, uint8) {
        if (msg.sender != address(entryPoint)) revert Unauthorized();
        uint256 frameIndex = entryPoint.txParam(0x0a);
        if (entryPoint.frameParam(frameIndex, 0x02) != T.VERIFY) revert Unauthorized();
        if (data.length != 0 && data.length != 32) revert Unauthorized();
        uint256 signatureIndex = data.length == 0 ? 0 : abi.decode(data, (uint256));
        _requireOwnerSignature(signatureIndex);
        uint8 scope = uint8(entryPoint.frameParam(frameIndex, 0x06));
        if (scope & T.PAYMENT != 0) {
            uint256 required = entryPoint.txParam(0x06);
            uint256 deposited = entryPoint.deposits(address(this));
            if (deposited < required) {
                entryPoint.depositTo{value: required - deposited}(address(this));
            }
        }
        return (T.VALIDATION_MAGIC, scope);
    }

    /// @notice Authorize SENDER calls in DEFAULT mode, leaving payment to a later VERIFY.
    function approveExecution(uint256 signatureIndex) external {
        if (
            msg.sender != address(entryPoint.defaultCaller())
                || entryPoint.frameParam(entryPoint.txParam(0x0a), 0x02) != T.DEFAULT
        ) revert Unauthorized();
        _requireOwnerSignature(signatureIndex);
        entryPoint.approveExecution();
    }

    function _requireOwnerSignature(uint256 signatureIndex) private view {
        uint256 scheme = entryPoint.sigParam(signatureIndex, 0x01);
        if (
            (scheme != T.SECP256K1 && scheme != T.P256)
                || entryPoint.sigParam(signatureIndex, 0x02) != 0
                || address(uint160(entryPoint.sigParam(signatureIndex, 0x00))) != owner
        ) revert Unauthorized();
    }

    function executeFrame(address target, uint256 value, bytes calldata data) external {
        if (
            msg.sender != address(entryPoint) || !entryPoint.isExecuting(address(this))
                || entryPoint.frameParam(entryPoint.txParam(0x0a), 0x02) != T.SENDER
        ) {
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
