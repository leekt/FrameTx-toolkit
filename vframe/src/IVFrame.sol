// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @notice Portable testing format. This is an ordinary contract ABI, not a native transaction.
library VFrameTypes {
    uint8 internal constant DEFAULT = 0;
    uint8 internal constant VERIFY = 1;
    uint8 internal constant SENDER = 2;
    uint8 internal constant PAYMENT = 1;
    uint8 internal constant EXECUTION = 2;
    uint8 internal constant BOTH = 3;
    uint8 internal constant ATOMIC = 4;
    bytes4 internal constant VALIDATION_MAGIC = bytes4(keccak256("vFrame.validation.v1"));

    struct Frame {
        uint8 mode;
        uint8 flags;
        address target; // Zero resolves to the transaction's sender account.
        uint64 gasLimit; // CALL/STATICCALL budget, including the DEFAULT router or SENDER adapter.
        uint256 value;
        bytes data; // Signed call data, or signed validator policy data for VERIFY.
    }

    struct Transaction {
        address sender;
        uint256[] nonceKeys; // Sorted, distinct; [0] is the default contract-managed sequence.
        uint64 nonce;
        uint48 validUntil; // Zero means no expiry.
        uint64 overheadGasLimit; // Budget for EntryPoint work outside the per-frame call budgets.
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        Frame[] frames;
        bytes[] authorizations; // One witness per frame; only VERIFY entries may be nonempty.
    }

    struct ValidationContext {
        bytes32 transactionHash;
        address sender;
        uint256 maxCost; // Maximum deposit reservation, not the final charge.
        uint256 gasPrice; // Outer gas price capped by the signed fee parameters.
        uint256 frameIndex;
        uint8 allowedScope;
    }

    struct GasQuote {
        uint256 gasLimit;
        uint256 maxCost;
        uint256 gasPrice;
    }

    struct Result {
        uint8 status; // 0 failed, 1 returned successfully, 2 skipped.
        bool rolledBack; // True for executed frames in a failed atomic group.
        bytes returnData; // Bounded; omitted for successful calls later rolled back.
    }
}

interface IVFrameValidator {
    /// @dev Called with STATICCALL. Return approval instead of mutating execution context.
    function validateFrame(
        VFrameTypes.ValidationContext calldata context,
        VFrameTypes.Frame[] calldata frames,
        bytes calldata authorization
    ) external view returns (bytes4 magic, uint8 approvedScope);
}

interface IVFrameAccount {
    /// @dev Must authenticate both the EntryPoint and its active SENDER dispatch.
    function executeFrame(address target, uint256 value, bytes calldata data) external;
}
