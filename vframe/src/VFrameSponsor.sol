// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {vFrame} from "./vFrame.sol";
import {VFrameTypes as T, IVFrameValidator} from "./IVFrame.sol";

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

    /// @dev The argument encodes a signature index; empty bytes select index zero.
    function validateFrame(bytes calldata data) external returns (bytes4, uint8) {
        if (msg.sender != address(entryPoint)) revert Unauthorized();
        uint256 frameIndex = entryPoint.txParam(0x0a);
        if (entryPoint.frameParam(frameIndex, 0x02) != T.VERIFY) revert Unauthorized();
        if (data.length != 0 && data.length != 32) revert Unauthorized();
        uint256 signatureIndex = data.length == 0 ? 0 : abi.decode(data, (uint256));
        uint256 scheme = entryPoint.sigParam(signatureIndex, 0x01);
        if (
            (scheme != T.SECP256K1 && scheme != T.P256)
                || entryPoint.sigParam(signatureIndex, 0x02) != 0
                || address(uint160(entryPoint.sigParam(signatureIndex, 0x00))) != owner
        ) revert Unauthorized();
        uint8 scope = uint8(entryPoint.frameParam(frameIndex, 0x06));
        if (scope != T.PAYMENT) revert Unauthorized();
        uint256 required = entryPoint.txParam(0x06);
        uint256 deposited = entryPoint.deposits(address(this));
        if (deposited < required) {
            entryPoint.depositTo{value: required - deposited}(address(this));
        }
        return (T.VALIDATION_MAGIC, scope);
    }

    function withdrawDeposit(address payable recipient, uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();
        entryPoint.withdrawTo(recipient, amount);
    }

    receive() external payable {}
}
