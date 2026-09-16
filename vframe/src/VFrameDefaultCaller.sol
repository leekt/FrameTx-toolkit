// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {VFrameCall} from "./VFrameCall.sol";

/// @notice Separate caller identity for DEFAULT frames, deployed by its vFrame EntryPoint.
/// @dev Stateless routing only. Calls from this address do not authenticate a sender account.
contract VFrameDefaultCaller {
    address public immutable entryPoint;

    error Unauthorized();

    constructor() {
        entryPoint = msg.sender;
    }

    /// @dev Only the deploying EntryPoint may route calls. Return/revert data stays transparent.
    function executeFrame(address target, bytes calldata data) external {
        if (msg.sender != entryPoint) revert Unauthorized();
        (bool success, bytes memory output) = VFrameCall.invoke(target, gasleft(), data);
        assembly ("memory-safe") {
            if iszero(success) { revert(add(output, 32), mload(output)) }
            return(add(output, 32), mload(output))
        }
    }
}
