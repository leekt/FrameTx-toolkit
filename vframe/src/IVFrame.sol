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
    uint8 internal constant ARBITRARY = 0;
    uint8 internal constant SECP256K1 = 1;
    uint8 internal constant P256 = 2;
    bytes4 internal constant VALIDATION_MAGIC = bytes4(keccak256("vFrame.validation.v1"));

    struct Frame {
        uint8 mode;
        uint8 flags;
        address target; // Zero resolves to the transaction's sender account.
        uint64 gasLimit; // CALL budget, including the DEFAULT router or SENDER adapter.
        uint256 value;
        bytes data; // Complete signed calldata, including the function selector, in every mode.
    }

    struct Signature {
        uint8 scheme; // SECP256K1/P256 are checked by vFrame; ARBITRARY is checked by the account.
        address signer; // Zero resolves to sender when a signer is exposed; unused for ARBITRARY.
        bytes32 message; // Zero denotes the vFrame transaction hash; otherwise an explicit digest.
        bytes signature; // SECP256K1: v (0/1) || r || s. P256: r || s || qx || qy.
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
        Signature[] signatures; // Independent of frames; signed frame data selects entries.
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
    /// @dev Optional example interface. vFrame CALLs frame.data without wrapping it.
    /// Authenticate the EntryPoint and VERIFY mode before authorizing or funding payment.
    function validateFrame(bytes calldata data) external returns (bytes4 magic, uint8 approvedScope);
}

interface IVFrameAccount {
    /// @dev Must authenticate both the EntryPoint and its active SENDER dispatch.
    function executeFrame(address target, uint256 value, bytes calldata data) external;
}

/// @notice Ordinary-call alternatives to native frame introspection instructions.
/// @dev Selectors follow EIP-8141/EIP-8250; unsupported native-only fields revert.
/// SECP256K1/P256 signer metadata is verified before frames execute. ARBITRARY has no signer.
interface IVFrameContext {
    function txParam(uint256 param) external view returns (uint256);
    function frameParam(uint256 frameIndex, uint256 param) external view returns (uint256);
    function sigParam(uint256 signatureIndex, uint256 param) external view returns (uint256);
    function frameData(uint256 frameIndex) external view returns (bytes memory);
    /// @dev Raw bytes are readable for all three schemes; ARBITRARY needs account validation.
    function signatureData(uint256 signatureIndex) external view returns (bytes memory);
}
