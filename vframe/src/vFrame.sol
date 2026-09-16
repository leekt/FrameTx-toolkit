// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {VFrameTypes as T, IVFrameAccount, IVFrameContext} from "./IVFrame.sol";
import {VFrameCall} from "./VFrameCall.sol";
import {VFrameDefaultCaller} from "./VFrameDefaultCaller.sol";
import {VFrameECDSA} from "./VFrameECDSA.sol";
import {VFrameP256} from "./VFrameP256.sol";

/// @notice A contract-only frame execution harness for stock EVMs.
/// @dev Test infrastructure: ABI envelopes, contract nonces and metered deposit payments.
/// Gas, receipts and account authority remain those of an ordinary outer transaction.
contract vFrame is IVFrameContext {
    uint256 public constant MAX_FRAMES = 64;
    bool public constant DEFAULT_EXECUTION_APPROVAL = true;
    uint256 public constant MAX_NONCE_KEYS = 16;
    uint256 public constant MAX_SIGNATURES = 64;
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
    bytes32 private constant SIGNATURE_TYPEHASH =
        keccak256("Signature(uint8 scheme,address signer,bytes32 message,bytes signature)");
    bytes32 private constant CONTEXT_SLOT = keccak256("vFrame.context.v2");
    bytes32 private constant TRANSACTION_TYPEHASH = keccak256(
        "Transaction(address sender,uint256[] nonceKeys,uint64 nonce,uint48 validUntil,uint64 overheadGasLimit,uint256 maxFeePerGas,uint256 maxPriorityFeePerGas,Frame[] frames,Signature[] signatures)Frame(uint8 mode,uint8 flags,address target,uint64 gasLimit,uint256 value,bytes data)Signature(uint8 scheme,address signer,bytes32 message,bytes signature)"
    );

    mapping(address account => uint256 balance) public deposits;
    mapping(address sender => mapping(uint256 key => uint64 sequence)) public nonces;
    bool private transient locked;
    address private transient executingSender;
    bool private transient contextActive;
    bool private transient senderApproved;
    uint256 private transient currentFrameIndex;

    error ReentrantCall();
    error NoActiveFrame();
    error InvalidContextParameter(uint256 param);
    error UnsupportedContextParameter(uint256 param);
    error ContextIndexOutOfBounds(uint256 index);
    error FrameNotCompleted(uint256 index);
    error SignatureFieldUnavailable(uint256 index);
    error InvalidSignature(uint256 index);
    error UnsupportedSignatureScheme(uint8 scheme);
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

    /// @notice Contract alternative to APPROVE(EXECUTION) during a DEFAULT frame.
    /// @dev Only the sender, while it is the current frame's target, can grant authority.
    /// Transient approval rolls back with the frame if its execution later reverts.
    function approveExecution() external {
        _requireContext();
        uint256 base = 0x100 + currentFrameIndex * 16;
        if (
            senderApproved || msg.sender != address(uint160(_load(0x02)))
                || msg.sender != address(uint160(_load(base))) || _load(base + 2) != T.DEFAULT
                || _load(base + 3) & T.EXECUTION == 0
        ) revert InvalidApproval(currentFrameIndex);
        senderApproved = true;
    }

    /// @notice EIP-8141/EIP-8250 selectors for the active virtual transaction.
    /// @dev Type is the virtual 0x06; hash and max cost use vFrame's ABI and gas model.
    function txParam(uint256 param) external view returns (uint256) {
        _requireContext();
        if (param > 0x10) revert InvalidContextParameter(param);
        // Ordinary contracts cannot read account-trie nonces or a native state-gas pool.
        if (param == 0x0c || param == 0x0d) revert UnsupportedContextParameter(param);
        if (param == 0x0a) return currentFrameIndex;
        if (param == 0x05 || param == 0x07) return 0; // vFrame has no blob fields.
        return _load(param);
    }

    /// @notice Inspect any frame's signed fields, or a completed frame's status.
    /// @dev Native state limits and execution/state receipt gas are not modeled.
    function frameParam(uint256 frameIndex, uint256 param) external view returns (uint256) {
        _requireFrame(frameIndex);
        if (param > 0x0b) revert InvalidContextParameter(param);
        if ((param == 0x05 || param >= 0x0a) && frameIndex >= currentFrameIndex) {
            revert FrameNotCompleted(frameIndex);
        }
        if (param >= 0x09) revert UnsupportedContextParameter(param);
        uint256 base = 0x100 + frameIndex * 16;
        if (param == 0x06) return _load(base + 3) & T.BOTH;
        if (param == 0x07) return (_load(base + 3) >> 2) & 1;
        return _load(base + param);
    }

    /// @notice SECP256K1/P256 signers are verified before any frame; ARBITRARY has no signer.
    function sigParam(uint256 signatureIndex, uint256 param) external view returns (uint256) {
        _requireSignature(signatureIndex);
        if (param > 0x03) revert InvalidContextParameter(param);
        uint256 base = 0x1000 + signatureIndex * 4;
        bool arbitrary = _load(base + 1) == T.ARBITRARY;
        if ((param == 0 && arbitrary) || (param == 3 && !arbitrary)) {
            revert SignatureFieldUnavailable(signatureIndex);
        }
        return _load(base + param);
    }

    function frameData(uint256 frameIndex) external view returns (bytes memory) {
        _requireFrame(frameIndex);
        return _readData(0, frameIndex, _load(0x100 + frameIndex * 16 + 4));
    }

    /// @notice Signature bytes. ARBITRARY witnesses must be verified by the consuming account.
    /// @dev Unlike native SIGDATACOPY, this harness exposes bytes for every scheme.
    function signatureData(uint256 signatureIndex) external view returns (bytes memory) {
        _requireSignature(signatureIndex);
        return _readData(1, signatureIndex, _load(0x1000 + signatureIndex * 4 + 3));
    }

    function _requireContext() private view {
        if (!contextActive) revert NoActiveFrame();
    }

    function _requireFrame(uint256 index) private view {
        _requireContext();
        if (index >= _load(0x09)) revert ContextIndexOutOfBounds(index);
    }

    function _requireSignature(uint256 index) private view {
        _requireContext();
        if (index >= _load(0x0b)) revert ContextIndexOutOfBounds(index);
    }

    function _store(uint256 key, uint256 value) private {
        bytes32 base = CONTEXT_SLOT;
        assembly ("memory-safe") { tstore(add(base, key), value) }
    }

    function _load(uint256 key) private view returns (uint256 value) {
        bytes32 base = CONTEXT_SLOT;
        assembly ("memory-safe") { value := tload(add(base, key)) }
    }

    function _dataKey(uint256 kind, uint256 index) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(CONTEXT_SLOT, kind, index)));
    }

    function _storeData(uint256 kind, uint256 index, bytes calldata data) private {
        uint256 base = _dataKey(kind, index);
        for (uint256 offset; offset < data.length; offset += 32) {
            uint256 word;
            assembly ("memory-safe") { word := calldataload(add(data.offset, offset)) }
            uint256 remaining = data.length - offset;
            // ABI padding need not be zero; never expose bytes beyond the declared length.
            if (remaining < 32) word = (word >> ((32 - remaining) * 8)) << ((32 - remaining) * 8);
            unchecked {
                _store(base + offset / 32, word);
            }
        }
    }

    function _readData(uint256 kind, uint256 index, uint256 size)
        private
        view
        returns (bytes memory data)
    {
        data = new bytes(size);
        uint256 base = _dataKey(kind, index);
        for (uint256 offset; offset < size; offset += 32) {
            uint256 word;
            unchecked {
                word = _load(base + offset / 32);
            }
            assembly ("memory-safe") { mstore(add(add(data, 32), offset), word) }
        }
    }

    function _openContext(T.Transaction calldata transaction, bytes32 hash, T.GasQuote memory quote)
        private
    {
        _store(0x00, 0x06);
        _store(0x01, transaction.nonce);
        _store(0x02, uint160(transaction.sender));
        _store(0x03, transaction.maxPriorityFeePerGas);
        _store(0x04, transaction.maxFeePerGas);
        _store(0x06, quote.maxCost);
        _store(0x08, uint256(hash));
        _store(0x09, transaction.frames.length);
        _store(0x0b, transaction.signatures.length);
        _store(0x0e, transaction.nonceKeys.length);
        _store(
            0x0f,
            uint256(
                keccak256(abi.encodePacked(transaction.nonceKeys.length, transaction.nonceKeys))
            )
        );
        _store(0x10, transaction.nonceKeys[0]);
        for (uint256 i; i < transaction.frames.length; ++i) {
            T.Frame calldata frame = transaction.frames[i];
            uint256 base = 0x100 + i * 16;
            _store(base, uint160(_target(frame, transaction.sender)));
            _store(base + 1, frame.gasLimit);
            _store(base + 2, frame.mode);
            _store(base + 3, frame.flags);
            _store(base + 4, frame.data.length);
            _store(base + 5, 0);
            _store(base + 8, frame.value);
            _storeData(0, i, frame.data);
        }
        for (uint256 i; i < transaction.signatures.length; ++i) {
            T.Signature calldata sig = transaction.signatures[i];
            uint256 base = 0x1000 + i * 4;
            _store(base, uint160(sig.signer == address(0) ? transaction.sender : sig.signer));
            _store(base + 1, sig.scheme);
            _store(base + 2, uint256(sig.message));
            _store(base + 3, sig.signature.length);
            _storeData(1, i, sig.signature);
        }
        contextActive = true;
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("vFrame"), keccak256("2"), block.chainid, address(this)
            )
        );
    }

    function _validateSignatures(T.Transaction calldata transaction, bytes32 transactionHash)
        private
        view
    {
        for (uint256 i; i < transaction.signatures.length; ++i) {
            T.Signature calldata sig = transaction.signatures[i];
            if (sig.scheme == T.ARBITRARY) {
                if (sig.signer != address(0)) revert InvalidSignature(i);
                continue;
            }
            address signer = sig.signer == address(0) ? transaction.sender : sig.signer;
            bytes32 digest = sig.message == bytes32(0) ? transactionHash : sig.message;
            if (sig.scheme == T.SECP256K1) {
                if (VFrameECDSA.recover(digest, sig.signature) != signer) {
                    revert InvalidSignature(i);
                }
            } else if (sig.scheme == T.P256) {
                if (!VFrameP256.verify(digest, sig.signature, signer)) revert InvalidSignature(i);
            } else {
                revert UnsupportedSignatureScheme(sig.scheme);
            }
        }
    }

    /// @notice EIP-712 hash bound to this deployment and chain. Canonical-hash witnesses are elided.
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
        bytes32[] memory signatureHashes = new bytes32[](transaction.signatures.length);
        for (uint256 i; i < signatureHashes.length; ++i) {
            T.Signature calldata sig = transaction.signatures[i];
            signatureHashes[i] = keccak256(
                abi.encode(
                    SIGNATURE_TYPEHASH,
                    sig.scheme,
                    sig.signer,
                    sig.message,
                    sig.message == bytes32(0) ? keccak256("") : keccak256(sig.signature)
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
                keccak256(abi.encodePacked(hashes)),
                keccak256(abi.encodePacked(signatureHashes))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), contents));
    }

    /// @notice Reserve at the signed upper price and clamp basefee to the signed price range.
    /// @dev maxFeePerGas is the floor; maxPriorityFeePerGas is the allowance above it.
    function getGasQuote(T.Transaction calldata transaction)
        public
        view
        returns (T.GasQuote memory quote)
    {
        if (
            transaction.overheadGasLimit < SETTLEMENT_GAS || transaction.frames.length == 0
                || transaction.frames.length > MAX_FRAMES
        ) revert InvalidGasParameters();
        quote.gasLimit = transaction.overheadGasLimit;
        for (uint256 i; i < transaction.frames.length; ++i) {
            uint256 limit = transaction.frames[i].gasLimit;
            if (limit == 0 || limit > MAX_FRAME_GAS) revert InvalidGasParameters();
            quote.gasLimit += limit;
        }
        if (transaction.maxPriorityFeePerGas > type(uint256).max - transaction.maxFeePerGas) {
            revert InvalidGasParameters();
        }
        uint256 upperPrice = transaction.maxFeePerGas + transaction.maxPriorityFeePerGas;
        if (quote.gasLimit > MAX_TRANSACTION_GAS || upperPrice > type(uint256).max / quote.gasLimit)
        {
            revert InvalidGasParameters();
        }
        quote.maxCost = quote.gasLimit * upperPrice;
        quote.gasPrice = block.basefee;
        if (quote.gasPrice < transaction.maxFeePerGas) quote.gasPrice = transaction.maxFeePerGas;
        if (quote.gasPrice > upperPrice) quote.gasPrice = upperPrice;
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
        _validateSignatures(transaction, transactionHash);
        _openContext(transaction, transactionHash, quote);
        results = new T.Result[](transaction.frames.length);
        senderApproved = false;
        address payer;

        for (uint256 i; i < transaction.frames.length;) {
            currentFrameIndex = i;
            T.Frame calldata frame = transaction.frames[i];
            if (frame.mode == T.VERIFY) {
                uint8 scope = _validateFrame(transaction.sender, frame, i);
                if (scope & T.EXECUTION != 0) {
                    if (senderApproved) revert InvalidApproval(i);
                    senderApproved = true;
                }
                if (scope & T.PAYMENT != 0) {
                    // A payer cannot consume another account's nonce without its approval.
                    if (!senderApproved) revert MissingExecutionApproval(i);
                    if (payer != address(0)) revert InvalidApproval(i);
                    payer = _target(frame, transaction.sender);
                    if (deposits[payer] < quote.maxCost) revert InsufficientDeposit(payer);
                    deposits[payer] -= quote.maxCost;
                    for (uint256 k; k < transaction.nonceKeys.length; ++k) {
                        nonces[transaction.sender][transaction.nonceKeys[k]] = transaction.nonce + 1;
                    }
                }
                results[i].status = 1;
                _store(0x100 + i * 16 + 5, 1);
                ++i;
                continue;
            }

            uint256 end = i;
            while (transaction.frames[end].flags & T.ATOMIC != 0) ++end;
            for (uint256 j = i; j <= end; ++j) {
                if (transaction.frames[j].mode == T.SENDER && !senderApproved) {
                    revert MissingExecutionApproval(j);
                }
            }
            if (end == i) {
                (bool success, bytes memory data) = _execute(transaction.sender, frame);
                results[i] = T.Result(success ? 1 : 0, false, data);
                _store(0x100 + i * 16 + 5, results[i].status);
            } else {
                _executeGroup(transaction.sender, transaction.frames, i, end, results);
            }
            i = end + 1;
        }
        contextActive = false;
        senderApproved = false;
        currentFrameIndex = 0;
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
            currentFrameIndex = i;
            (bool success, bytes memory data) = _execute(sender, frames[i]);
            _store(0x100 + i * 16 + 5, success ? 1 : 0);
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
            // The nested call rolled back its context writes as well as application state.
            for (uint256 i = start; i <= end; ++i) {
                _store(0x100 + i * 16 + 5, results[i].status);
            }
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
        (bool success, bytes memory output) = VFrameCall.invoke(target, frame.gasLimit, data);
        executingSender = address(0);
        return (success, output);
    }

    function _validateFrame(address sender, T.Frame calldata frame, uint256 index)
        private
        returns (uint8 scope)
    {
        _requireGas(frame.gasLimit);
        (bool success, bytes memory output) =
            VFrameCall.invoke(_target(frame, sender), frame.gasLimit, frame.data);
        if (!success || output.length != 64) revert ValidationFailed(index, output);
        (bytes4 magic, uint8 approvedScope) = abi.decode(output, (bytes4, uint8));
        if (magic != T.VALIDATION_MAGIC || approvedScope & ~(frame.flags & T.BOTH) != 0) {
            revert InvalidApproval(index);
        }
        return approvedScope;
    }

    function _validateShape(T.Transaction calldata transaction) private view {
        uint256 count = transaction.frames.length;
        if (
            transaction.sender == address(0) || transaction.sender == address(this) || count == 0
                || count > MAX_FRAMES || transaction.signatures.length > MAX_SIGNATURES
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
                    || (frame.mode == T.SENDER && frame.flags & T.BOTH != 0)
                    || (frame.mode == T.DEFAULT && frame.flags & T.PAYMENT != 0)
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
