// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @dev Bounds copied returndata, including data supplied by untrusted targets.
library VFrameCall {
    uint256 internal constant MAX_RETURN_DATA = 2048;

    function invoke(address target, uint256 gasLimit, bytes memory data, bool readOnly)
        internal
        returns (bool success, bytes memory output)
    {
        uint256 cap = MAX_RETURN_DATA;
        assembly ("memory-safe") {
            switch readOnly
            case 1 { success := staticcall(gasLimit, target, add(data, 32), mload(data), 0, 0) }
            default { success := call(gasLimit, target, 0, add(data, 32), mload(data), 0, 0) }
            let size := returndatasize()
            if gt(size, cap) { size := cap }
            output := mload(0x40)
            mstore(output, size)
            returndatacopy(add(output, 32), 0, size)
            mstore(0x40, and(add(add(output, 63), size), not(31)))
        }
    }
}
