// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {VFrameTypes as T, IVFrameValidator, IVFrameAccount} from "./IVFrame.sol";
import {VFrameCall} from "./VFrameCall.sol";
import {VFrameDefaultCaller} from "./VFrameDefaultCaller.sol";

/// @notice A contract-only frame execution harness for stock EVMs.
/// @dev Test infrastructure: ABI envelopes, contract nonces and metered deposit payments.
/// Gas, receipts and account authority remain those of an ordinary outer transaction.
contract vFrame {
    uint256 public constant MAX_FRAMES = 64;
    uint256 public constant MAX_NONCE_KEYS = 16;
    uint256 public constant MAX_FRAME_GAS = 10_000_000;
    uint256 public constant MAX_TRANSACTION_GAS = 16_777_216;
    // Allowance for deposit settlement, the final event, return encoding and lock cleanup.
    uint256 public constant SETTLEMENT_GAS = 40_000;

    VFrameDefaultCaller public immutable defaultCaller;

    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant FRAME_TYPEHASH = keccak256(
        "Frame(uint8 mode,uint8 flags,address target,uint64 gasLimit,uint256 value,bytes data)"
    );
    bytes32 private constant TRANSACTION_TYPEHASH = keccak256(
        "Transaction(address sender,uint256[] nonceKeys,uint64 nonce,uint48 validUntil,uint64 overheadGasLimit,uint256 maxFeePerGas,uint256 maxPriorityFeePerGas,Frame[] frames)Frame(uint8 mode,uint8 flags,address target,uint64 gasLimit,uint256 value,bytes data)"
    );

    mapping(address account => uint256 balance) public deposits;
    mapping(address sender => mapping(uint256 key => uint64 sequence)) public nonces;
    bool private transient locked;
    address private transient executingSender;

    error ReentrantCall();
    error InvalidTransaction();
    error InvalidFrame(uint256 index);
    error NonceMismatch(uint256 key, uint64 expected, uint64 supplied);
    error ValidationFailed(uint256 index, bytes reason);
    error InvalidApproval(uint256 index);
    error MissingExecutionApproval(uint256 index);
    error MissingPaymentApproval();
    error InsufficientDeposit(address payer);
    error InsufficientOuterGas();
    error InvalidGasParameters();
    error GasBudgetExceeded(uint256 gasUsed, uint256 gasLimit);
    error OnlySelf();
    error BatchReverted(uint256 failedIndex, bytes reason);
    error BatchEngineFailure(bytes reason);
    error TransferFailed();

    event Deposited(address indexed account, address indexed from, uint256 amount);
    event Withdrawn(address indexed account, address indexed recipient, uint256 amount);
    event FrameResult(
        bytes32 indexed transactionHash,
        uint256 indexed index,
        uint8 status,
        bool rolledBack,
        bytes returnData
    );
    event TransactionHandled(
        bytes32 indexed transactionHash,
        address indexed sender,
        address indexed payer,
        address relayer,
        uint256 gasUsed,
        uint256 gasPrice,
        uint256 chargedFee,
        uint256 refund
    );

    modifier nonReentrant() {
        if (locked) revert ReentrantCall();
        locked = true;
        _;
        locked = false;
    }

    constructor() {
        defaultCaller = new VFrameDefaultCaller();
    }

    function depositTo(address account) external payable {
        deposits[account] += msg.value;
        emit Deposited(account, msg.sender, msg.value);
    }

    function withdrawTo(address payable recipient, uint256 amount) external nonReentrant {
        if (deposits[msg.sender] < amount) revert InsufficientDeposit(msg.sender);
        deposits[msg.sender] -= amount;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Withdrawn(msg.sender, recipient, amount);
    }

    /// @notice Accounts check this as well as msg.sender to require an active SENDER dispatch.
    function isExecuting(address account) external view returns (bool) {
        return locked && account != address(0) && executingSender == account;
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("vFrame"), keccak256("1"), block.chainid, address(this)
            )
        );
    }

    /// @notice EIP-712 hash bound to this deployment and chain. Witnesses are excluded.
    function getTransactionHash(T.Transaction calldata transaction) public view returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](transaction.frames.length);
        for (uint256 i; i < hashes.length; ++i) {
            T.Frame calldata frame = transaction.frames[i];
            hashes[i] = keccak256(
                abi.encode(
                    FRAME_TYPEHASH,
                    frame.mode,
                    frame.flags,
                    frame.target,
                    frame.gasLimit,
                    frame.value,
                    keccak256(frame.data)
                )
            );
        }
        bytes32 contents = keccak256(
            abi.encode(
                TRANSACTION_TYPEHASH,
                transaction.sender,
                keccak256(abi.encodePacked(transaction.nonceKeys)),
                transaction.nonce,
                transaction.validUntil,
                transaction.overheadGasLimit,
                transaction.maxFeePerGas,
                transaction.maxPriorityFeePerGas,
                keccak256(abi.encodePacked(hashes))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), contents));
    }

    /// @notice Maximum reservation and capped reimbursement price for the current call context.
    /// @dev Set gasPrice when using eth_call; an omitted/zero price produces a zero charge.
    function getGasQuote(T.Transaction calldata transaction)
        public
        view
        returns (T.GasQuote memory quote)
    {
        if (
            transaction.overheadGasLimit < SETTLEMENT_GAS
                || transaction.maxPriorityFeePerGas > transaction.maxFeePerGas
                || transaction.maxFeePerGas < block.basefee || transaction.frames.length == 0
                || transaction.frames.length > MAX_FRAMES
        ) revert InvalidGasParameters();
        quote.gasLimit = transaction.overheadGasLimit;
        for (uint256 i; i < transaction.frames.length; ++i) {
            uint256 limit = transaction.frames[i].gasLimit;
            if (limit == 0 || limit > MAX_FRAME_GAS) revert InvalidGasParameters();
            quote.gasLimit += limit;
        }
        if (
            quote.gasLimit > MAX_TRANSACTION_GAS
                || transaction.maxFeePerGas > type(uint256).max / quote.gasLimit
        ) revert InvalidGasParameters();
        quote.maxCost = quote.gasLimit * transaction.maxFeePerGas;
        uint256 tip = transaction.maxFeePerGas - block.basefee;
        if (tip > transaction.maxPriorityFeePerGas) tip = transaction.maxPriorityFeePerGas;
        quote.gasPrice = block.basefee + tip;
        if (quote.gasPrice > tx.gasprice) quote.gasPrice = tx.gasprice;
    }

    /// @notice Relay one signed operation using a normal transaction, or preview its results with eth_call.
    function handle(T.Transaction calldata transaction)
        external
        nonReentrant
        returns (T.Result[] memory results)
    {
        uint256 startGas = gasleft();
        _validateShape(transaction);
        T.GasQuote memory quote = getGasQuote(transaction);
        bytes32 transactionHash = getTransactionHash(transaction);
        results = new T.Result[](transaction.frames.length);
        bool approved;
        address payer;

        for (uint256 i; i < transaction.frames.length;) {
            T.Frame calldata frame = transaction.frames[i];
            if (frame.mode == T.VERIFY) {
                uint8 scope = _validateFrame(transaction, transactionHash, quote, i);
                if (scope & T.EXECUTION != 0) {
                    if (approved) revert InvalidApproval(i);
                    approved = true;
                }
                if (scope & T.PAYMENT != 0) {
                    // A payer cannot consume another account's nonce without its approval.
                    if (!approved) revert MissingExecutionApproval(i);
                    if (payer != address(0)) revert InvalidApproval(i);
                    payer = _target(frame, transaction.sender);
                    if (deposits[payer] < quote.maxCost) revert InsufficientDeposit(payer);
                    deposits[payer] -= quote.maxCost;
                    for (uint256 k; k < transaction.nonceKeys.length; ++k) {
                        nonces[transaction.sender][transaction.nonceKeys[k]] = transaction.nonce + 1;
                    }
                }
                results[i].status = 1;
                ++i;
                continue;
            }

            uint256 end = i;
            while (transaction.frames[end].flags & T.ATOMIC != 0) ++end;
            for (uint256 j = i; j <= end; ++j) {
                if (transaction.frames[j].mode == T.SENDER && !approved) {
                    revert MissingExecutionApproval(j);
                }
            }
            if (end == i) {
                (bool success, bytes memory data) = _execute(transaction.sender, frame);
                results[i] = T.Result(success ? 1 : 0, false, data);
            } else {
                _executeGroup(transaction.sender, transaction.frames, i, end, results);
            }
            i = end + 1;
        }
        if (payer == address(0)) revert MissingPaymentApproval();
        for (uint256 i; i < results.length; ++i) {
            emit FrameResult(
                transactionHash, i, results[i].status, results[i].rolledBack, results[i].returnData
            );
        }
        _settle(transactionHash, transaction.sender, payer, quote, startGas);
    }

    function _settle(
        bytes32 transactionHash,
        address sender,
        address payer,
        T.GasQuote memory quote,
        uint256 startGas
    ) private {
        // gasleft() measures reverted calls and batches too; skipped calls consume no call budget.
        uint256 gasUsed = startGas - gasleft() + SETTLEMENT_GAS;
        if (gasUsed > quote.gasLimit) revert GasBudgetExceeded(gasUsed, quote.gasLimit);
        uint256 chargedFee = gasUsed * quote.gasPrice;
        uint256 refund = quote.maxCost - chargedFee;
        deposits[payer] += refund;
        deposits[msg.sender] += chargedFee;
        emit TransactionHandled(
            transactionHash, sender, payer, msg.sender, gasUsed, quote.gasPrice, chargedFee, refund
        );
    }

    /// @dev A nested call provides an ordinary EVM rollback boundary for the entire group.
    /// The dispatcher forbids targeting this EntryPoint, so user calldata cannot reach this as self.
    function executeGroup(address sender, T.Frame[] calldata frames, uint256 start, uint256 end)
        external
        returns (bytes[] memory outputs)
    {
        if (msg.sender != address(this) || !locked) revert OnlySelf();
        outputs = new bytes[](end - start + 1);
        for (uint256 i = start; i <= end; ++i) {
            (bool success, bytes memory data) = _execute(sender, frames[i]);
            if (!success) revert BatchReverted(i, data);
            outputs[i - start] = data;
        }
    }

    function _executeGroup(
        address sender,
        T.Frame[] calldata frames,
        uint256 start,
        uint256 end,
        T.Result[] memory results
    ) private {
        try this.executeGroup(sender, frames, start, end) returns (bytes[] memory outputs) {
            for (uint256 i = start; i <= end; ++i) {
                results[i] = T.Result(1, false, outputs[i - start]);
            }
        } catch (bytes memory reason) {
            if (reason.length < 100 || bytes4(reason) != BatchReverted.selector) {
                revert BatchEngineFailure(reason);
            }
            uint256 failed;
            assembly ("memory-safe") { failed := mload(add(reason, 36)) }
            if (failed < start || failed > end) revert BatchEngineFailure(reason);
            for (uint256 i = start; i <= end; ++i) {
                results[i].status = i < failed ? 1 : (i == failed ? 0 : 2);
                results[i].rolledBack = i <= failed;
            }
            // Preserve the wrapper error (failed index plus bounded original revert data).
            results[failed].returnData = reason;
        }
    }

    function _execute(address sender, T.Frame calldata frame) private returns (bool, bytes memory) {
        address target = _target(frame, sender);
        bytes memory data = frame.data;
        if (frame.mode == T.SENDER) {
            // Calling an EOA's nonexistent adapter must never count as successful execution.
            if (sender.code.length == 0) {
                return (false, abi.encodePacked("vFrame: sender has no adapter"));
            }
            executingSender = sender;
            data = abi.encodeCall(IVFrameAccount.executeFrame, (target, frame.value, frame.data));
            target = sender;
        } else {
            data = abi.encodeCall(VFrameDefaultCaller.executeFrame, (target, frame.data));
            target = address(defaultCaller);
        }
        _requireGas(frame.gasLimit);
        (bool success, bytes memory output) = VFrameCall.invoke(target, frame.gasLimit, data, false);
        executingSender = address(0);
        return (success, output);
    }

    function _validateFrame(
        T.Transaction calldata transaction,
        bytes32 transactionHash,
        T.GasQuote memory quote,
        uint256 index
    ) private returns (uint8 scope) {
        T.Frame calldata frame = transaction.frames[index];
        T.ValidationContext memory context = T.ValidationContext(
            transactionHash,
            transaction.sender,
            quote.maxCost,
            quote.gasPrice,
            index,
            frame.flags & T.BOTH
        );
        bytes memory input = abi.encodeCall(
            IVFrameValidator.validateFrame,
            (context, transaction.frames, transaction.authorizations[index])
        );
        _requireGas(frame.gasLimit);
        (bool success, bytes memory output) =
            VFrameCall.invoke(_target(frame, transaction.sender), frame.gasLimit, input, true);
        if (!success || output.length != 64) revert ValidationFailed(index, output);
        (bytes4 magic, uint8 approvedScope) = abi.decode(output, (bytes4, uint8));
        if (magic != T.VALIDATION_MAGIC || approvedScope & ~context.allowedScope != 0) {
            revert InvalidApproval(index);
        }
        return approvedScope;
    }

    function _validateShape(T.Transaction calldata transaction) private view {
        uint256 count = transaction.frames.length;
        if (
            transaction.sender == address(0) || transaction.sender == address(this) || count == 0
                || count > MAX_FRAMES || transaction.authorizations.length != count
                || transaction.nonceKeys.length == 0
                || transaction.nonceKeys.length > MAX_NONCE_KEYS
                || transaction.nonce == type(uint64).max
                || (transaction.validUntil != 0 && block.timestamp > transaction.validUntil)
        ) revert InvalidTransaction();
        for (uint256 k; k < transaction.nonceKeys.length; ++k) {
            uint256 key = transaction.nonceKeys[k];
            if (
                (k != 0 && transaction.nonceKeys[k - 1] >= key)
                    || (key == 0 && transaction.nonceKeys.length != 1)
            ) revert InvalidTransaction();
            uint64 expected = nonces[transaction.sender][key];
            if (expected != transaction.nonce) {
                revert NonceMismatch(key, expected, transaction.nonce);
            }
        }
        for (uint256 i; i < count; ++i) {
            T.Frame calldata frame = transaction.frames[i];
            bool atomic = frame.flags & T.ATOMIC != 0;
            bool inGroup = atomic || (i != 0 && transaction.frames[i - 1].flags & T.ATOMIC != 0);
            address target = _target(frame, transaction.sender);
            if (
                frame.mode > T.SENDER || frame.flags > 7 || frame.gasLimit == 0
                    || frame.gasLimit > MAX_FRAME_GAS || target == address(this)
                    || (frame.mode != T.SENDER && frame.value != 0)
                    || (frame.mode != T.VERIFY
                        && (frame.flags & T.BOTH != 0 || transaction.authorizations[i].length != 0))
                    || (frame.flags & T.EXECUTION != 0 && target != transaction.sender)
                    || (atomic
                        && (frame.mode == T.VERIFY
                            || i + 1 == count
                            || transaction.frames[i + 1].mode == T.VERIFY))
                    || (inGroup && frame.flags & T.BOTH != 0)
            ) revert InvalidFrame(i);
        }
    }

    function _target(T.Frame calldata frame, address sender) private pure returns (address) {
        return frame.target == address(0) ? sender : frame.target;
    }

    function _requireGas(uint256 amount) private view {
        // Avoid silently forwarding less than the signed budget under EIP-150.
        // The reserve covers CALL overhead, account access and local result handling.
        if (gasleft() < amount + amount / 63 + 20_000) revert InsufficientOuterGas();
    }
}
