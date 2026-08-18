// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";

interface IHarness {
    function txType() external view returns (uint256);
    function txNonce() external view returns (uint256);
    function txSender() external view returns (address);
    function maxPriorityFeePerGas() external view returns (uint256);
    function maxFeePerGas() external view returns (uint256);
    function maxFeePerBlobGas() external view returns (uint256);
    function maxCost() external view returns (uint256);
    function blobCount() external view returns (uint256);
    function sigHash() external view returns (bytes32);
    function frameCount() external view returns (uint256);
    function currentFrameIndex() external view returns (uint256);
    function signatureCount() external view returns (uint256);
    function legacyNonce() external view returns (uint256);
    function nonceKeyCount() external view returns (uint256);
    function nonceKeysHash() external view returns (bytes32);
    function recentRootReferenceCount() external view returns (uint256);
    function firstNonceKey() external view returns (uint256);
    function recentRootSourceId(uint256 i) external view returns (bytes32);
    function recentRootSlot(uint256 i) external view returns (uint256);
    function recentRoot(uint256 i) external view returns (bytes32);
    function frameTarget(uint256 i) external view returns (address);
    function frameGasLimit(uint256 i) external view returns (uint256);
    function stateGasLeft() external view returns (uint256);
    function frameStateGasLimit(uint256 i) external view returns (uint256);
    function frameExecutionGasUsed(uint256 i) external view returns (uint256);
    function frameStateGasUsed(uint256 i) external view returns (uint256);
    function frameMode(uint256 i) external view returns (uint256);
    function frameFlags(uint256 i) external view returns (uint256);
    function frameDataLength(uint256 i) external view returns (uint256);
    function frameStatus(uint256 i) external view returns (uint256);
    function frameAllowedScope(uint256 i) external view returns (uint256);
    function frameIsAtomicBatch(uint256 i) external view returns (bool);
    function frameValue(uint256 i) external view returns (uint256);
    function frameDataLoad(uint256 i, uint256 offset) external view returns (bytes32);
    function frameDataSlice(uint256 i, uint256 offset, uint256 length) external view returns (bytes memory);
    function frameData(uint256 i) external view returns (bytes memory);
    function isExpiryFrame(uint256 i) external view returns (bool);
    function expiryDeadline(uint256 i) external view returns (uint64);
    function sigSigner(uint256 i) external view returns (address);
    function sigScheme(uint256 i) external view returns (uint256);
    function sigMsg(uint256 i) external view returns (bytes32);
    function signedThisTx(uint256 i) external view returns (bool);
    function sigLength(uint256 i) external view returns (uint256);
    function sigDataSlice(uint256 i, uint256 offset, uint256 length) external view returns (bytes memory);
    function sigData(uint256 i) external view returns (bytes memory);
    function traceBalanceDiffCount() external view returns (uint256);
    function traceStorageDiffCount() external view returns (uint256);
    function traceDeploymentCount() external view returns (uint256);
    function traceBalanceAccount(uint256 i) external view returns (address);
    function traceBalanceBefore(uint256 i) external view returns (uint256);
    function traceBalanceAfter(uint256 i) external view returns (uint256);
    function traceStorageAccount(uint256 i) external view returns (address);
    function traceStorageKey(uint256 i) external view returns (uint256);
    function traceStorageBefore(uint256 i) external view returns (uint256);
    function traceStorageAfter(uint256 i) external view returns (uint256);
    function traceDeployedAccount(uint256 i) external view returns (address);
    function traceDeployedCodeHash(uint256 i) external view returns (bytes32);
    function traceEventCount() external view returns (uint256);
    function traceEventEmitter(uint256 i) external view returns (address);
    function traceEventTopicCount(uint256 i) external view returns (uint256);
    function traceEventTopic0(uint256 i) external view returns (bytes32);
    function traceEventTopic1(uint256 i) external view returns (bytes32);
    function traceEventTopic2(uint256 i) external view returns (bytes32);
    function traceEventTopic3(uint256 i) external view returns (bytes32);
    function traceEventDataLength(uint256 i) external view returns (uint256);
    function traceGasPreCharge() external view returns (uint256);
    function traceGasPayer() external view returns (address);
    function storageValueBefore(address account, uint256 key) external view returns (uint256);
    function storageValueAfter(address account, uint256 key) external view returns (uint256);
    function accountBalanceBefore(address account) external view returns (uint256);
    function accountBalanceAfter(address account) external view returns (uint256);
    function accountCodeHashBefore(address account) external view returns (bytes32);
    function accountCodeHashAfter(address account) external view returns (bytes32);
    function accountStorageDiffCount(address account) external view returns (uint256);
    function accountStorageDiffIndex(address account, uint256 localIndex) external view returns (uint256);
    function accountEventCount(address account) external view returns (uint256);
    function accountEventIndex(address account, uint256 localIndex) external view returns (uint256);
    function accountDiffFlags(address account) external view returns (uint256);
    function eventDataSlice(uint256 eventIndex, uint256 dataOffset, uint256 length) external view returns (bytes memory);
    function eventData(uint256 eventIndex) external view returns (bytes memory);
    function approve(uint256 scope) external;
    function approveWithData(uint256 scope, bytes calldata data) external;
}

/// Every FrameTxLib wrapper executed against the real opcodes, pinned to a
/// fixture rich enough that a swapped operand or off-by-one index cannot pass.
contract FrameTxLibTest is FrameTest {
    address constant HARNESS = address(0x11B);
    IHarness constant h = IHarness(HARNESS);

    bytes constant FRAME0_DATA = hex"6901f668";
    bytes constant FRAME1_DATA = hex"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff0102";
    bytes constant ARB_SIG = hex"deadbeef00000000000000000000000000000000000000000000000000000000c0ffee";
    address constant SIGNER = address(0x0BEEF);
    bytes32 constant SIG_HASH = keccak256("sig hash");
    bytes32 constant OTHER_MSG = keccak256("some other digest");
    bytes32 constant NONCE_KEYS_HASH = 0x12164bf9476413f64229734534ebb103701111099e71b229191a85aacab75697;

    address constant TRACE_ACCOUNT_A = address(0x1000);
    address constant TRACE_ACCOUNT_B = address(0x2000);
    address constant TRACE_DEPLOYED = address(0x3000);
    address constant TRACE_GAS_PAYER = address(0x4000);

    bytes32 constant SOURCE_ID_0 = keccak256("source 0");
    bytes32 constant SOURCE_ID_1 = keccak256("source 1");
    bytes32 constant RECENT_ROOT_0 = keccak256("recent root 0");
    bytes32 constant RECENT_ROOT_1 = keccak256("recent root 1");
    bytes32 constant DEPLOYED_CODE_HASH = keccak256("deployed code");
    bytes32 constant CODE_HASH_BEFORE = keccak256("code before");
    bytes32 constant CODE_HASH_AFTER = keccak256("code after");
    bytes32 constant TOPIC_0 = keccak256("topic 0");
    bytes32 constant TOPIC_1 = keccak256("topic 1");
    bytes32 constant TOPIC_2 = keccak256("topic 2");
    bytes32 constant TOPIC_3 = keccak256("topic 3");

    function setUp() public {
        deployAccount("FrameTxLibHarness", HARNESS);
    }

    function _trace() internal pure returns (IFrameVm.FrameTxTrace memory trace) {
        trace.balanceDiffs = new IFrameVm.FrameTxBalanceDiff[](2);
        trace.balanceDiffs[0] =
            IFrameVm.FrameTxBalanceDiff({account: TRACE_ACCOUNT_A, balanceBefore: 10, balanceAfter: 7});
        trace.balanceDiffs[1] =
            IFrameVm.FrameTxBalanceDiff({account: TRACE_ACCOUNT_B, balanceBefore: 20, balanceAfter: 25});

        trace.storageDiffs = new IFrameVm.FrameTxStorageDiff[](3);
        trace.storageDiffs[0] =
            IFrameVm.FrameTxStorageDiff({account: TRACE_ACCOUNT_A, key: 1, valueBefore: 0, valueAfter: 11});
        trace.storageDiffs[1] =
            IFrameVm.FrameTxStorageDiff({account: TRACE_ACCOUNT_A, key: 2, valueBefore: 3, valueAfter: 4});
        trace.storageDiffs[2] =
            IFrameVm.FrameTxStorageDiff({account: TRACE_ACCOUNT_B, key: 9, valueBefore: 5, valueAfter: 6});

        trace.deployedContracts = new IFrameVm.FrameTxDeployedContract[](1);
        trace.deployedContracts[0] =
            IFrameVm.FrameTxDeployedContract({account: TRACE_DEPLOYED, codeHash: DEPLOYED_CODE_HASH});

        trace.accountDiffs = new IFrameVm.FrameTxAccountDiff[](1);
        trace.accountDiffs[0] = IFrameVm.FrameTxAccountDiff({
            account: TRACE_ACCOUNT_A,
            nonceChanged: true,
            codeHashBefore: CODE_HASH_BEFORE,
            codeHashAfter: CODE_HASH_AFTER
        });

        trace.events = new IFrameVm.FrameTxEvent[](3);
        trace.events[0].emitter = TRACE_ACCOUNT_B;
        trace.events[0].topics = new bytes32[](1);
        trace.events[0].topics[0] = keccak256("event 0 topic");
        trace.events[0].data = hex"010203";

        trace.events[1].emitter = TRACE_ACCOUNT_A;
        trace.events[1].topics = new bytes32[](4);
        trace.events[1].topics[0] = TOPIC_0;
        trace.events[1].topics[1] = TOPIC_1;
        trace.events[1].topics[2] = TOPIC_2;
        trace.events[1].topics[3] = TOPIC_3;
        trace.events[1].data = hex"040506070809";

        trace.events[2].emitter = TRACE_ACCOUNT_B;
        trace.events[2].topics = new bytes32[](0);
        trace.events[2].data = hex"aabbccdd";

        trace.gasPreCharge = 1_000;
        trace.gasPayer = TRACE_GAS_PAYER;
    }

    /// Two frames -- frame 0 already succeeded and frame 1 is the current
    /// fixture-only POST_TX frame -- plus host-supplied nonce keys, recent roots,
    /// signatures, ordered state diffs, deployments and globally ordered events.
    function _ctx() internal pure returns (IFrameVm.FrameTx memory ctx) {
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](2);
        frames[0] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: 0x3,
            target: address(0xACC0),
            gasLimit: 100_000,
            stateGasLimit: 20_000,
            value: 0,
            data: FRAME0_DATA,
            status: 1,
            executionGasUsed: 90_000,
            stateGasUsed: 15_000
        });
        frames[1] = IFrameVm.FrameTxFrame({
            mode: MODE_POST_TX,
            // Bit 2 set: part of an atomic batch. Low bits 0: no approvals.
            flags: 0x4,
            target: HARNESS,
            gasLimit: 500_000,
            stateGasLimit: 30_000,
            value: 42 ether,
            data: FRAME1_DATA,
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });

        IFrameVm.FrameTxSignature[] memory sigs = new IFrameVm.FrameTxSignature[](2);
        sigs[0] = IFrameVm.FrameTxSignature({scheme: 1, signer: SIGNER, msgHash: bytes32(0), signature: ""});
        sigs[1] = IFrameVm.FrameTxSignature({scheme: 0, signer: address(0), msgHash: OTHER_MSG, signature: ARB_SIG});

        uint256[] memory nonceKeys = new uint256[](2);
        nonceKeys[0] = 0xB0B;
        nonceKeys[1] = 0xA11CE;

        IFrameVm.FrameTxRecentRootReference[] memory recentRoots = new IFrameVm.FrameTxRecentRootReference[](2);
        recentRoots[0] = IFrameVm.FrameTxRecentRootReference({sourceId: SOURCE_ID_0, slot: 123, root: RECENT_ROOT_0});
        recentRoots[1] = IFrameVm.FrameTxRecentRootReference({sourceId: SOURCE_ID_1, slot: 456, root: RECENT_ROOT_1});

        ctx.sender = address(0xACC0);
        ctx.nonce = 7;
        ctx.legacyNonce = 11;
        ctx.nonceKeys = nonceKeys;
        ctx.nonceKeysHash = NONCE_KEYS_HASH;
        ctx.stateGasLeft = 25_000;
        ctx.sigHash = SIG_HASH;
        ctx.maxCost = 1 ether;
        ctx.maxPriorityFeePerGas = 2 gwei;
        ctx.maxFeePerGas = 30 gwei;
        ctx.maxFeePerBlobGas = 4 gwei;
        ctx.blobCount = 3;
        ctx.frameIndex = 1;
        ctx.frames = frames;
        ctx.signatures = sigs;
        ctx.recentRootReferences = recentRoots;
        ctx.trace = _trace();
        ctx.approvableScopes = SCOPE_BOTH;
    }

    modifier inFrame() {
        fvm.setFrameTx(_ctx());
        _;
        fvm.clearFrameTx();
    }

    function _assertHarnessCallFails(bytes memory data, string memory reason) internal {
        (bool ok,) = HARNESS.call(data);
        assertFalse(ok, reason);
    }

    function test_txScope() public inFrame {
        assertEq(h.txType(), 0x06, "txType");
        assertEq(h.txNonce(), 7, "nonce");
        assertEq(h.txSender(), address(0xACC0), "sender");
        assertEq(h.maxPriorityFeePerGas(), 2 gwei, "maxPriorityFeePerGas");
        assertEq(h.maxFeePerGas(), 30 gwei, "maxFeePerGas");
        assertEq(h.maxFeePerBlobGas(), 4 gwei, "maxFeePerBlobGas");
        assertEq(h.maxCost(), 1 ether, "maxCost");
        assertEq(h.blobCount(), 3, "blobCount");
        assertEq(h.sigHash(), SIG_HASH, "sigHash");
        assertEq(h.frameCount(), 2, "frameCount");
        assertEq(h.currentFrameIndex(), 1, "currentFrameIndex");
        assertEq(h.signatureCount(), 2, "signatureCount");
        assertEq(h.stateGasLeft(), 25_000, "stateGasLeft");
        assertEq(h.legacyNonce(), 11, "legacyNonce");
        assertEq(h.nonceKeyCount(), 2, "nonceKeyCount");
        assertEq(h.nonceKeysHash(), NONCE_KEYS_HASH, "nonceKeysHash");
        assertEq(h.recentRootReferenceCount(), 2, "recentRootReferenceCount");
        assertEq(h.firstNonceKey(), 0xB0B, "firstNonceKey");
    }

    function test_recentRootReferences() public inFrame {
        assertEq(h.recentRootSourceId(1), SOURCE_ID_1, "recent-root source id");
        assertEq(h.recentRootSlot(1), 456, "recent-root slot");
        assertEq(h.recentRoot(1), RECENT_ROOT_1, "recent root");
    }

    function test_frameScope() public inFrame {
        assertEq(h.frameTarget(0), address(0xACC0), "frame 0 target");
        assertEq(h.frameMode(0), 1, "frame 0 mode VERIFY");
        assertEq(h.frameFlags(0), 0x3, "frame 0 flags");
        assertEq(h.frameAllowedScope(0), 3, "frame 0 allowed scope");
        assertEq(h.frameStatus(0), 1, "frame 0 status SUCCESS");
        assertFalse(h.frameIsAtomicBatch(0), "frame 0 not atomic");

        assertEq(h.frameTarget(1), HARNESS, "frame 1 target");
        assertEq(h.frameMode(1), MODE_POST_TX, "frame 1 mode POST_TX");
        assertEq(h.frameGasLimit(1), 500_000, "frame 1 execution gas limit");
        assertEq(h.frameStateGasLimit(0), 20_000, "frame 0 state gas limit");
        assertEq(h.frameStateGasLimit(1), 30_000, "frame 1 state gas limit");
        assertEq(h.frameExecutionGasUsed(0), 90_000, "frame 0 receipt execution gas");
        assertEq(h.frameStateGasUsed(0), 15_000, "frame 0 receipt state gas");
        assertEq(h.frameValue(1), 42 ether, "frame 1 value");
        assertEq(h.frameAllowedScope(1), 0, "frame 1 allowed scope");
        assertTrue(h.frameIsAtomicBatch(1), "frame 1 atomic");
    }

    function test_frameData() public inFrame {
        assertEq(h.frameDataLength(1), FRAME1_DATA.length, "frame 1 data length");
        assertEq(h.frameData(1), FRAME1_DATA, "frame 1 full data");
        assertEq(h.frameData(0), FRAME0_DATA, "frame 0 full data");
        // A word loaded straight, a word loaded past the end (zero-padded),
        // and a slice crossing the end.
        assertEq(
            h.frameDataLoad(1, 0),
            bytes32(0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff),
            "word at 0"
        );
        assertEq(
            h.frameDataLoad(1, 32),
            bytes32(0x0102000000000000000000000000000000000000000000000000000000000000),
            "word at 32 zero-padded"
        );
        assertEq(
            h.frameDataSlice(1, 32, 4), abi.encodePacked(hex"0102", new bytes(2)), "slice crossing the end zero-filled"
        );
    }

    /// An expiry verifier frame is recognised by mode + target, and its 8-byte
    /// big-endian deadline read back from the left-aligned FRAMEDATALOAD word.
    function test_expiryFrame() public {
        IFrameVm.FrameTx memory ctx = _ctx();
        ctx.frames[0].target = address(0x8141);
        ctx.frames[0].data = abi.encodePacked(uint64(1_234_567_890));
        fvm.setFrameTx(ctx);
        assertTrue(h.isExpiryFrame(0), "frame 0 is the expiry frame");
        assertEq(h.expiryDeadline(0), 1_234_567_890, "deadline");
        assertFalse(h.isExpiryFrame(1), "frame 1 is not");
        fvm.clearFrameTx();
    }

    function test_nonExpiryFrameNotRecognised() public inFrame {
        // Frame 0 is a VERIFY frame, but targets the account, not 0x8141.
        assertFalse(h.isExpiryFrame(0), "ordinary VERIFY frame is not an expiry frame");
    }

    function test_sigScope() public inFrame {
        assertEq(h.sigScheme(0), 1, "sig 0 scheme SECP256K1");
        assertEq(h.sigSigner(0), SIGNER, "sig 0 resolved signer");
        assertEq(h.sigMsg(0), bytes32(0), "sig 0 msg");
        assertTrue(h.signedThisTx(0), "sig 0 signed this tx");

        assertEq(h.sigScheme(1), 0, "sig 1 scheme ARBITRARY");
        assertEq(h.sigMsg(1), OTHER_MSG, "sig 1 explicit msg");
        assertFalse(h.signedThisTx(1), "sig 1 signed something else");
    }

    /// The raw-bytes read behind sigData is native SIGDATACOPY, executed end
    /// to end against revm.
    function test_sigData() public inFrame {
        assertEq(h.sigLength(1), ARB_SIG.length, "sig 1 length");
        assertEq(h.sigData(1), ARB_SIG, "sig 1 full bytes");
        assertEq(h.sigDataSlice(1, 32, 3), hex"c0ffee", "sig 1 tail slice");
        assertEq(h.sigDataSlice(1, 32, 8), abi.encodePacked(hex"c0ffee", new bytes(5)), "sig 1 slice zero-filled");
    }

    function test_txTraceBalanceStorageAndDeployments() public inFrame {
        assertEq(h.traceBalanceDiffCount(), 2, "balance diff count");
        assertEq(h.traceStorageDiffCount(), 3, "storage diff count");
        assertEq(h.traceDeploymentCount(), 1, "deployment count");

        assertEq(h.traceBalanceAccount(1), TRACE_ACCOUNT_B, "balance account");
        assertEq(h.traceBalanceBefore(1), 20, "balance before");
        assertEq(h.traceBalanceAfter(1), 25, "balance after");

        assertEq(h.traceStorageAccount(2), TRACE_ACCOUNT_B, "storage account");
        assertEq(h.traceStorageKey(2), 9, "storage key");
        assertEq(h.traceStorageBefore(2), 5, "storage before");
        assertEq(h.traceStorageAfter(2), 6, "storage after");

        assertEq(h.traceDeployedAccount(0), TRACE_DEPLOYED, "deployed account");
        assertEq(h.traceDeployedCodeHash(0), DEPLOYED_CODE_HASH, "deployed code hash");
    }

    function test_txTraceEventsAndGas() public inFrame {
        assertEq(h.traceEventCount(), 3, "event count");
        assertEq(h.traceEventEmitter(1), TRACE_ACCOUNT_A, "event emitter");
        assertEq(h.traceEventTopicCount(1), 4, "event topic count");
        assertEq(h.traceEventTopic0(1), TOPIC_0, "event topic 0");
        assertEq(h.traceEventTopic1(1), TOPIC_1, "event topic 1");
        assertEq(h.traceEventTopic2(1), TOPIC_2, "event topic 2");
        assertEq(h.traceEventTopic3(1), TOPIC_3, "event topic 3");
        assertEq(h.traceEventDataLength(1), 6, "event data length");
        assertEq(h.traceGasPreCharge(), 1_000, "gas pre-charge");
        assertEq(h.traceGasPayer(), TRACE_GAS_PAYER, "gas payer");
    }

    function test_txDiff() public inFrame {
        assertEq(h.storageValueBefore(TRACE_ACCOUNT_A, 2), 3, "storage value before");
        assertEq(h.storageValueAfter(TRACE_ACCOUNT_A, 2), 4, "storage value after");
        assertEq(h.accountBalanceBefore(TRACE_ACCOUNT_B), 20, "account balance before");
        assertEq(h.accountBalanceAfter(TRACE_ACCOUNT_B), 25, "account balance after");
        assertEq(h.accountCodeHashBefore(TRACE_ACCOUNT_A), CODE_HASH_BEFORE, "code hash before");
        assertEq(h.accountCodeHashAfter(TRACE_ACCOUNT_A), CODE_HASH_AFTER, "code hash after");
        assertEq(h.accountStorageDiffCount(TRACE_ACCOUNT_A), 2, "account storage count");
        assertEq(h.accountStorageDiffIndex(TRACE_ACCOUNT_B, 0), 2, "global storage index");
        assertEq(h.accountEventCount(TRACE_ACCOUNT_B), 2, "account event count");
        assertEq(h.accountEventIndex(TRACE_ACCOUNT_B, 1), 2, "global event index");
        assertEq(h.accountDiffFlags(TRACE_ACCOUNT_A), 0x0F, "account diff flags");
    }

    function test_eventData() public inFrame {
        assertEq(h.eventData(1), hex"040506070809", "full event data");
        assertEq(h.eventDataSlice(1, 1, 3), hex"050607", "event data slice");
        assertEq(h.eventDataSlice(1, 3, 3), hex"070809", "slice ending at source bound");
    }

    function test_invalidRecentRootIndexHalts() public inFrame {
        _assertHarnessCallFails(abi.encodeCall(IHarness.recentRoot, (2)), "recent-root index past the end must fail");
    }

    function test_emptyNonceKeyListHalts() public {
        IFrameVm.FrameTx memory ctx = _ctx();
        ctx.nonceKeys = new uint256[](0);
        fvm.setFrameTx(ctx);
        _assertHarnessCallFails(
            abi.encodeCall(IHarness.firstNonceKey, ()), "first nonce key of an empty list must fail"
        );
        fvm.clearFrameTx();
    }

    function test_outOfRangeFrameAndSignatureIndexesHalt() public inFrame {
        _assertHarnessCallFails(abi.encodeCall(IHarness.frameTarget, (2)), "frame index past the end must fail");
        _assertHarnessCallFails(abi.encodeCall(IHarness.sigScheme, (2)), "signature index past the end must fail");
    }

    function test_outOfRangeGlobalAndLocalTraceIndexesHalt() public inFrame {
        _assertHarnessCallFails(
            abi.encodeCall(IHarness.traceBalanceAccount, (2)), "global balance-diff index past the end must fail"
        );
        _assertHarnessCallFails(
            abi.encodeCall(IHarness.accountStorageDiffIndex, (TRACE_ACCOUNT_A, 2)),
            "account-local storage index past the end must fail"
        );
        _assertHarnessCallFails(
            abi.encodeCall(IHarness.accountEventIndex, (TRACE_ACCOUNT_A, 1)),
            "account-local event index past the end must fail"
        );
    }

    function test_outOfRangeEventAndTopicIndexesHalt() public inFrame {
        _assertHarnessCallFails(
            abi.encodeCall(IHarness.eventDataSlice, (3, 0, 0)), "event-data index past the end must fail"
        );
        _assertHarnessCallFails(abi.encodeCall(IHarness.traceEventTopic1, (0)), "missing topic index must fail");
    }

    function test_traceOpcodesOutsidePostTxHalt() public {
        IFrameVm.FrameTx memory ctx = _ctx();
        ctx.frames[ctx.frameIndex].mode = MODE_DEFAULT;
        fvm.setFrameTx(ctx);

        (bool traceOk,) = HARNESS.call(abi.encodeCall(IHarness.traceBalanceDiffCount, ()));
        (bool diffOk,) = HARNESS.call(abi.encodeCall(IHarness.accountBalanceBefore, (TRACE_ACCOUNT_A)));
        (bool eventOk,) = HARNESS.call(abi.encodeCall(IHarness.eventDataSlice, (1, 0, 1)));

        assertFalse(traceOk, "TXTRACE outside POST_TX must fail");
        assertFalse(diffOk, "TXDIFF outside POST_TX must fail");
        assertFalse(eventOk, "EVENTDATACOPY outside POST_TX must fail");
        fvm.clearFrameTx();
    }

    function test_eventDataSourceOverrunHalts() public inFrame {
        _assertHarnessCallFails(
            abi.encodeCall(IHarness.eventDataSlice, (1, 4, 3)), "EVENTDATACOPY must not zero-fill past event data"
        );
    }

    /// Reading the raw bytes of a protocol-verified entry must halt: the spec
    /// keeps those opaque so schemes can be aggregated later.
    function test_sigDataOfProtocolSchemeHalts() public inFrame {
        _assertHarnessCallFails(abi.encodeCall(IHarness.sigData, (0)), "copying SECP256K1 bytes must fail");
    }

    /// Asking an ARBITRARY entry for its resolved signer must halt: there is
    /// none -- the protocol verified nothing.
    function test_sigSignerOfArbitraryHalts() public inFrame {
        _assertHarnessCallFails(abi.encodeCall(IHarness.sigSigner, (1)), "resolved signer of ARBITRARY must fail");
    }

    /// The signature length of a protocol-verified entry is not readable:
    /// raw bytes stay opaque, length included (EIPs PR 12187).
    function test_sigLengthOfProtocolSchemeHalts() public inFrame {
        _assertHarnessCallFails(abi.encodeCall(IHarness.sigLength, (0)), "length of SECP256K1 bytes must fail");
    }

    /// Receipt gas of the current frame does not exist yet, like its status.
    function test_currentFrameReceiptGasHalts() public inFrame {
        _assertHarnessCallFails(
            abi.encodeCall(IHarness.frameExecutionGasUsed, (1)), "gas_used.execution of the current frame must fail"
        );
        _assertHarnessCallFails(
            abi.encodeCall(IHarness.frameStateGasUsed, (1)), "gas_used.state of the current frame must fail"
        );
    }

    /// The status of the current frame is not readable.
    function test_currentFrameStatusHalts() public inFrame {
        _assertHarnessCallFails(abi.encodeCall(IHarness.frameStatus, (1)), "status of the current frame must fail");
    }

    function test_txParamWithoutContextHalts() public {
        _assertHarnessCallFails(abi.encodeCall(IHarness.txType, ()), "TXPARAM needs frame context");
    }

    function test_approve() public {
        IFrameVm.FrameTx memory ctx = verifyContext(HARNESS, SCOPE_BOTH, SIG_HASH);
        ctx.frames[0].data = abi.encodeCall(IHarness.approve, (SCOPE_BOTH));
        assertApprovesFrame(HARNESS, ctx, "approve(SCOPE_BOTH) should succeed");
    }

    function test_approveWithReturnData() public {
        bytes memory expected = hex"decafbad00112233";
        IFrameVm.FrameTx memory ctx = verifyContext(HARNESS, SCOPE_BOTH, SIG_HASH);
        ctx.frames[0].data = abi.encodeCall(IHarness.approveWithData, (SCOPE_BOTH, expected));
        fvm.setFrameTx(ctx);

        (bool ok, bytes memory returnData) = HARNESS.call(ctx.frames[0].data);

        assertTrue(ok, "approve(scope, data) should succeed");
        assertEq(returnData, expected, "APPROVE must return the exact unencoded bytes");
        fvm.clearFrameTx();
    }

    function test_approveBeyondAllowedScopeFails() public {
        IFrameVm.FrameTx memory ctx = verifyContext(HARNESS, SCOPE_PAYMENT, SIG_HASH);
        ctx.frames[0].data = abi.encodeCall(IHarness.approve, (SCOPE_BOTH));
        assertRefusesFrame(HARNESS, ctx, "scope must be a subset of the frame's flags");
    }
}
