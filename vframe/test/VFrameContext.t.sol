// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {vFrame} from "../src/vFrame.sol";
import {VFrameAccount} from "../src/VFrameAccount.sol";
import {VFrameTypes as T, IVFrameContext, IVFrameValidator} from "../src/IVFrame.sol";

contract ContextReader is IVFrameValidator {
    vFrame public immutable ep;

    constructor(vFrame ep_) {
        ep = ep_;
    }

    // A nested read preserves the active virtual frame, regardless of ordinary msg.sender.
    function read(bytes calldata query) external view {
        (bool success, bytes memory output) = address(ep).staticcall(query);
        assembly ("memory-safe") {
            if iszero(success) { revert(add(output, 32), mload(output)) }
            return(add(output, 32), mload(output))
        }
    }

    function validateFrame(bytes calldata data) external view returns (bytes4, uint8) {
        require(msg.sender == address(ep), "entrypoint");
        uint256 index = ep.txParam(0x0a);
        uint256 count = ep.txParam(0x09);
        require(ep.frameParam(index, 0x02) == T.VERIFY, "mode");
        require(ep.frameParam(index, 0x00) == uint160(address(this)), "target");
        require(keccak256(msg.data) == keccak256(ep.frameData(index)), "frame data");
        if (data.length != 0) {
            (uint256 expectedIndex, uint256 expectedCount) = abi.decode(data, (uint256, uint256));
            require(index == expectedIndex && count == expectedCount, "context");
        }
        for (uint256 i; i < count; ++i) {
            uint256 flags = ep.frameParam(i, 0x03);
            require(ep.frameParam(i, 0x04) == ep.frameData(i).length, "length");
            require(ep.frameParam(i, 0x06) == flags & T.BOTH, "scope");
            require(ep.frameParam(i, 0x07) == (flags >> 2) & 1, "atomic");
        }
        return (T.VALIDATION_MAGIC, 0);
    }
}

contract ArbitraryAccount is IVFrameValidator {
    vFrame public immutable ep;
    bytes32 public immutable witnessHash;

    constructor(vFrame ep_, bytes memory witness) {
        ep = ep_;
        witnessHash = keccak256(witness);
    }

    function validateFrame(bytes calldata) external view returns (bytes4, uint8) {
        require(msg.sender == address(ep), "entrypoint");
        require(ep.sigParam(0, 1) == T.ARBITRARY, "scheme");
        require(ep.sigParam(0, 2) == 0, "message");
        require(keccak256(ep.signatureData(0)) == witnessHash, "witness");
        return (T.VALIDATION_MAGIC, T.BOTH);
    }
}

contract VFrameContextTest is Test {
    vFrame internal ep;
    VFrameAccount internal account;
    ContextReader internal reader;
    uint256 internal constant KEY = 0xa11ce;

    function setUp() public {
        ep = new vFrame();
        account = new VFrameAccount(ep, vm.addr(KEY));
        reader = new ContextReader(ep);
        vm.deal(address(this), 10 ether);
        ep.depositTo{value: 1 ether}(address(account));
        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei);
    }

    function _transaction(uint256 count) internal view returns (T.Transaction memory tx_) {
        tx_.sender = address(account);
        tx_.nonceKeys = new uint256[](1);
        tx_.nonce = ep.nonces(address(account), 0);
        tx_.overheadGasLimit = 500_000;
        tx_.maxFeePerGas = 3 gwei;
        tx_.maxPriorityFeePerGas = 1 gwei;
        tx_.frames = new T.Frame[](count);
        tx_.frames[0] = T.Frame(
            T.VERIFY,
            T.BOTH,
            address(0),
            200_000,
            0,
            abi.encodeCall(IVFrameValidator.validateFrame, (bytes("")))
        );
        for (uint256 i = 1; i < count; ++i) {
            tx_.frames[i] = _read(abi.encodeCall(IVFrameContext.txParam, (0x0a)));
        }
        tx_.signatures = new T.Signature[](1);
        tx_.signatures[0].scheme = T.SECP256K1;
        tx_.signatures[0].signer = vm.addr(KEY);
    }

    function _read(bytes memory query) internal view returns (T.Frame memory) {
        return T.Frame(
            T.DEFAULT, 0, address(reader), 200_000, 0, abi.encodeCall(ContextReader.read, (query))
        );
    }

    function _sign(T.Transaction memory tx_) internal view {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, ep.getTransactionHash(tx_));
        tx_.signatures[0].signature = abi.encodePacked(uint8(v - 27), r, s);
    }

    function _word(T.Result memory result) internal pure returns (uint256) {
        require(result.status == 1, "reader failed");
        return abi.decode(result.returnData, (uint256));
    }

    function test_allReadersRejectOutsideExecutionAndAfterSuccess() public {
        bytes[] memory queries = new bytes[](5);
        queries[0] = abi.encodeCall(IVFrameContext.txParam, (0));
        queries[1] = abi.encodeCall(IVFrameContext.frameParam, (0, 0));
        queries[2] = abi.encodeCall(IVFrameContext.sigParam, (0, 0));
        queries[3] = abi.encodeCall(IVFrameContext.frameData, (0));
        queries[4] = abi.encodeCall(IVFrameContext.signatureData, (0));
        T.Transaction memory tx_ = _transaction(1);
        for (uint256 round; round < 2; ++round) {
            for (uint256 i; i < queries.length; ++i) {
                (bool ok, bytes memory error) = address(ep).staticcall(queries[i]);
                assertFalse(ok);
                assertEq(error, abi.encodeWithSelector(vFrame.NoActiveFrame.selector));
            }
            if (round == 0) {
                _sign(tx_);
                ep.handle(tx_);
            }
        }
    }

    function test_verifyReceivesFrameDataAndReadsContext() public {
        T.Transaction memory tx_ = _transaction(4);
        tx_.frames[1] = T.Frame(
            T.VERIFY,
            0,
            address(reader),
            500_000,
            0,
            abi.encodeCall(IVFrameValidator.validateFrame, (abi.encode(uint256(1), uint256(4))))
        );
        tx_.frames[2].mode = T.SENDER;
        tx_.frames[2].flags = T.ATOMIC;
        _sign(tx_);
        T.Result[] memory results = ep.handle(tx_);
        assertEq(results[1].status, 1);
        assertEq(_word(results[2]), 2);
        assertEq(_word(results[3]), 3);
    }

    function test_transactionSelectorsAndKeyHashStayStableAfterNonceConsumption() public {
        T.Transaction memory tx_ = _transaction(16);
        tx_.nonceKeys = new uint256[](2);
        tx_.nonceKeys[0] = 7;
        tx_.nonceKeys[1] = 9;
        uint256[15] memory selectors = [uint256(0), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 15, 16];
        for (uint256 i; i < selectors.length; ++i) {
            tx_.frames[i + 1] = _read(abi.encodeCall(IVFrameContext.txParam, (selectors[i])));
        }
        _sign(tx_);
        uint256[15] memory expected = [
            uint256(6),
            0,
            uint160(address(account)),
            1 gwei,
            3 gwei,
            0,
            ep.getGasQuote(tx_).maxCost,
            0,
            uint256(ep.getTransactionHash(tx_)),
            16,
            11,
            1,
            2,
            uint256(keccak256(abi.encodePacked(uint256(2), uint256(7), uint256(9)))),
            7
        ];
        T.Result[] memory results = ep.handle(tx_);
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(_word(results[i + 1]), expected[i]);
        }
        assertEq(ep.nonces(address(account), 7), 1);
        assertEq(ep.nonces(address(account), 9), 1);
    }

    function test_statusInsideAtomicGroupAndAfterRollback() public {
        T.Transaction memory tx_ = _transaction(8);
        tx_.frames[1].flags = T.ATOMIC;
        tx_.frames[2] = _read(abi.encodeCall(IVFrameContext.frameParam, (1, 5)));
        tx_.frames[2].flags = T.ATOMIC;
        // Reading the current status must fail; the rest of this group is skipped.
        tx_.frames[3] = _read(abi.encodeCall(IVFrameContext.frameParam, (3, 5)));
        tx_.frames[3].flags = T.ATOMIC;
        for (uint256 i = 5; i < 8; ++i) {
            tx_.frames[i] = _read(abi.encodeCall(IVFrameContext.frameParam, (i - 3, 5)));
        }
        _sign(tx_);
        T.Result[] memory results = ep.handle(tx_);
        assertEq(results[2].status, 1);
        assertTrue(results[2].rolledBack);
        assertEq(results[3].status, 0);
        assertEq(results[4].status, 2);
        assertEq(_word(results[5]), 1);
        assertEq(_word(results[6]), 0);
        assertEq(_word(results[7]), 2);
    }

    function test_contextSurvivesFailedCallsAndRejectsFutureStatus() public {
        T.Transaction memory tx_ = _transaction(4);
        tx_.frames[1] = _read(abi.encodeCall(IVFrameContext.frameParam, (2, 5)));
        tx_.frames[2] = _read(abi.encodeCall(IVFrameContext.frameParam, (1, 5)));
        _sign(tx_);
        T.Result[] memory results = ep.handle(tx_);
        assertEq(
            results[1].returnData, abi.encodeWithSelector(vFrame.FrameNotCompleted.selector, 2)
        );
        assertEq(_word(results[2]), 0);
        assertEq(_word(results[3]), 3);
    }

    function test_invalidIndicesSelectorsAndUnsupportedNativeFieldsRevert() public {
        bytes[] memory queries = new bytes[](10);
        queries[0] = abi.encodeCall(IVFrameContext.frameParam, (type(uint256).max, 0));
        queries[1] = abi.encodeCall(IVFrameContext.sigParam, (1, 0));
        queries[2] = abi.encodeCall(IVFrameContext.txParam, (0x11));
        queries[3] = abi.encodeCall(IVFrameContext.frameParam, (0, 0x0c));
        queries[4] = abi.encodeCall(IVFrameContext.sigParam, (0, 4));
        queries[5] = abi.encodeCall(IVFrameContext.txParam, (0x0c));
        queries[6] = abi.encodeCall(IVFrameContext.txParam, (0x0d));
        queries[7] = abi.encodeCall(IVFrameContext.frameParam, (0, 9));
        queries[8] = abi.encodeCall(IVFrameContext.frameParam, (0, 10));
        queries[9] = abi.encodeCall(IVFrameContext.frameParam, (0, 11));
        T.Transaction memory tx_ = _transaction(11);
        for (uint256 i; i < queries.length; ++i) {
            tx_.frames[i + 1] = _read(queries[i]);
        }
        _sign(tx_);
        T.Result[] memory results = ep.handle(tx_);
        for (uint256 i = 1; i < results.length; ++i) {
            assertEq(results[i].status, 0);
        }
        assertEq(
            results[1].returnData,
            abi.encodeWithSelector(vFrame.ContextIndexOutOfBounds.selector, type(uint256).max)
        );
        assertEq(
            results[6].returnData,
            abi.encodeWithSelector(vFrame.UnsupportedContextParameter.selector, 0x0c)
        );
    }

    function test_signatureMetadataAndRawByteRestrictions() public {
        T.Transaction memory tx_ = _transaction(8);
        T.Signature[] memory signatures = new T.Signature[](2);
        signatures[0] = tx_.signatures[0];
        signatures[1] = T.Signature(T.ARBITRARY, address(0), bytes32(uint256(123)), hex"010203");
        tx_.signatures = signatures;
        tx_.frames[1] = _read(abi.encodeCall(IVFrameContext.sigParam, (0, 0)));
        tx_.frames[2] = _read(abi.encodeCall(IVFrameContext.sigParam, (0, 1)));
        tx_.frames[3] = _read(abi.encodeCall(IVFrameContext.sigParam, (0, 2)));
        tx_.frames[4] = _read(abi.encodeCall(IVFrameContext.sigParam, (0, 3)));
        tx_.frames[5] = _read(abi.encodeCall(IVFrameContext.signatureData, (0)));
        tx_.frames[6] = _read(abi.encodeCall(IVFrameContext.sigParam, (1, 0)));
        tx_.frames[7] = _read(abi.encodeCall(IVFrameContext.sigParam, (1, 2)));
        _sign(tx_);
        T.Result[] memory results = ep.handle(tx_);
        assertEq(_word(results[1]), uint160(vm.addr(KEY)));
        assertEq(_word(results[2]), T.SECP256K1);
        assertEq(_word(results[3]), 0);
        for (uint256 i = 4; i <= 6; ++i) {
            if (i == 5) continue;
            assertEq(results[i].status, 0);
            assertEq(
                results[i].returnData,
                abi.encodeWithSelector(vFrame.SignatureFieldUnavailable.selector, i == 6 ? 1 : 0)
            );
        }
        assertEq(abi.decode(results[5].returnData, (bytes)), tx_.signatures[0].signature);
        assertEq(_word(results[7]), 123);
    }

    function test_arbitraryWitnessCanAuthorizeThroughContextReaders() public {
        ArbitraryAccount custom = new ArbitraryAccount(ep, hex"123456");
        T.Transaction memory tx_ = _transaction(1);
        tx_.sender = address(custom);
        tx_.signatures[0] = T.Signature(T.ARBITRARY, address(0), bytes32(0), hex"123456");
        ep.depositTo{value: 1 ether}(address(custom));
        assertEq(ep.handle(tx_)[0].status, 1);
        assertEq(ep.nonces(address(custom), 0), 1);
    }

    function test_declaredSignerCannotForgeApprovalAndFailedContextClears() public {
        T.Transaction memory tx_ = _transaction(2);
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(123, ep.getTransactionHash(tx_));
        // Metadata claims the owner, but the witness was signed by someone else.
        tx_.signatures[0].signature = abi.encodePacked(uint8(v - 27), r, ss);
        vm.expectPartialRevert(vFrame.InvalidSignature.selector);
        ep.handle(tx_);
        assertEq(ep.nonces(address(account), 0), 0);
        assertEq(ep.deposits(address(account)), 1 ether);
        vm.expectRevert(vFrame.NoActiveFrame.selector);
        ep.txParam(0);
        _sign(tx_);
        assertEq(ep.handle(tx_)[1].status, 1);
    }

    function test_signatureCountIsIndependentOfFrameCountAndBounded() public {
        T.Transaction memory tx_ = _transaction(1);
        tx_.signatures = new T.Signature[](ep.MAX_SIGNATURES() + 1);
        vm.expectRevert(vFrame.InvalidTransaction.selector);
        ep.handle(tx_);
        tx_.signatures = new T.Signature[](0);
        tx_.frames[0].target = address(reader);
        tx_.frames[0].flags = 0;
        vm.expectRevert(vFrame.MissingPaymentApproval.selector);
        ep.handle(tx_); // The empty list reaches validation; payment is the missing condition.
    }

    function test_signatureHashBindsMetadataAndOnlyExplicitDigestWitnesses() public view {
        T.Transaction memory tx_ = _transaction(1);
        bytes32 canonical = ep.getTransactionHash(tx_);
        tx_.signatures[0].signature = hex"1234";
        assertEq(ep.getTransactionHash(tx_), canonical);
        tx_.signatures[0].signer = address(0);
        assertNotEq(ep.getTransactionHash(tx_), canonical);
        tx_.signatures[0].signer = vm.addr(KEY);
        tx_.signatures[0].scheme = T.P256;
        assertNotEq(ep.getTransactionHash(tx_), canonical);
        tx_.signatures[0].scheme = T.SECP256K1;
        tx_.signatures[0].message = bytes32(uint256(123));
        bytes32 explicitDigest = ep.getTransactionHash(tx_);
        assertNotEq(explicitDigest, canonical);
        tx_.signatures[0].signature = hex"5678";
        assertNotEq(ep.getTransactionHash(tx_), explicitDigest);
    }

    function test_explicitDigestCannotAuthorizeCanonicalTransaction() public {
        T.Transaction memory tx_ = _transaction(1);
        tx_.signatures[0].message = keccak256("another message");
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(KEY, tx_.signatures[0].message);
        tx_.signatures[0].signature = abi.encodePacked(uint8(v - 27), r, ss);
        vm.expectPartialRevert(vFrame.ValidationFailed.selector);
        ep.handle(tx_);
    }

    function testFuzz_frameAndSignatureBytesRoundTrip(bytes memory data) public {
        vm.assume(data.length <= 192);
        T.Transaction memory tx_ = _transaction(4);
        tx_.signatures = new T.Signature[](2);
        tx_.signatures[0] = T.Signature(T.SECP256K1, vm.addr(KEY), bytes32(0), "");
        tx_.signatures[1] = T.Signature(T.ARBITRARY, address(0), bytes32(0), data);
        tx_.frames[1] = _read(abi.encodeCall(IVFrameContext.signatureData, (1)));
        tx_.frames[2] = _read(abi.encodeCall(IVFrameContext.frameData, (3)));
        tx_.frames[3] = T.Frame(T.DEFAULT, 0, address(0x1234), 50_000, 0, data);
        _sign(tx_);
        T.Result[] memory results = ep.handle(tx_);
        assertEq(results[1].status, 1);
        assertEq(results[2].status, 1);
        assertEq(abi.decode(results[1].returnData, (bytes)), data);
        assertEq(abi.decode(results[2].returnData, (bytes)), data);
    }

    function test_shorterSecondOperationCannotReadStaleBytesOrEntries() public {
        T.Transaction memory tx_ = _transaction(4);
        tx_.signatures = new T.Signature[](2);
        tx_.signatures[0] = T.Signature(T.SECP256K1, vm.addr(KEY), bytes32(0), "");
        tx_.signatures[1] = T.Signature(T.ARBITRARY, address(0), bytes32(0), new bytes(96));
        tx_.frames[1] = _read(abi.encodeCall(IVFrameContext.signatureData, (1)));
        tx_.frames[2] = _read(abi.encodeCall(IVFrameContext.frameData, (3)));
        tx_.frames[3] = T.Frame(T.DEFAULT, 0, address(0x1234), 50_000, 0, new bytes(97));
        _sign(tx_);
        ep.handle(tx_);
        tx_.nonce = 1;
        tx_.signatures[1].signature = hex"1234";
        tx_.frames[3].data = hex"56";
        _sign(tx_);
        T.Result[] memory second = ep.handle(tx_);
        assertEq(abi.decode(second[1].returnData, (bytes)), hex"1234");
        assertEq(abi.decode(second[2].returnData, (bytes)), hex"56");
        T.Transaction memory third = _transaction(2);
        third.frames[1] = _read(abi.encodeCall(IVFrameContext.sigParam, (1, 1)));
        _sign(third);
        T.Result[] memory result = ep.handle(third);
        assertEq(
            result[1].returnData, abi.encodeWithSelector(vFrame.ContextIndexOutOfBounds.selector, 1)
        );
    }
}
