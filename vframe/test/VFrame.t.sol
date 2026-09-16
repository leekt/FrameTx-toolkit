// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {vFrame} from "../src/vFrame.sol";
import {VFrameAccount} from "../src/VFrameAccount.sol";
import {VFrameSponsor} from "../src/VFrameSponsor.sol";
import {VFrameDefaultCaller} from "../src/VFrameDefaultCaller.sol";
import {VFrameTypes as T, IVFrameAccount, IVFrameValidator} from "../src/IVFrame.sol";

contract Probe {
    uint256 public value;
    address public caller;
    uint256 public received;
    bool public reentrySucceeded;

    function write(uint256 next) external payable returns (uint256) {
        value = next;
        caller = msg.sender;
        received += msg.value;
        return next;
    }

    function fail() external pure {
        revert("probe rejected");
    }

    function exhaustGas() external pure {
        assembly { for {} 1 {} {} }
    }

    function largeReturn() external pure {
        assembly { return(0, 65536) }
    }

    function largeRevert() external pure {
        assembly { revert(0, 65536) }
    }

    function reenter(vFrame entryPoint, bytes calldata input) external {
        (reentrySucceeded,) = address(entryPoint).call(input);
    }
}

contract PolicyValidator is IVFrameValidator {
    address public immutable allowedTarget;

    constructor(address allowedTarget_) {
        allowedTarget = allowedTarget_;
    }

    function validateFrame(bytes calldata data) external view returns (bytes4, uint8) {
        vFrame ep = vFrame(msg.sender);
        require(keccak256(data) == keccak256("policy"), "policy data");
        for (uint256 i; i < ep.txParam(0x09); ++i) {
            if (ep.frameParam(i, 0x02) == T.SENDER) {
                require(address(uint160(ep.frameParam(i, 0x00))) == allowedTarget, "target denied");
            }
        }
        return (T.VALIDATION_MAGIC, 0);
    }
}

// A custom validation selector demonstrates raw mutable VERIFY dispatch.
contract StatefulValidator {
    uint256 public writes;

    function checkAndWrite(uint256 next) external returns (bytes4, uint8) {
        vFrame ep = vFrame(msg.sender);
        require(ep.frameParam(ep.txParam(0x0a), 0x02) == T.VERIFY, "mode");
        writes = next;
        return (T.VALIDATION_MAGIC, 0);
    }
}

contract BadScopeValidator is IVFrameValidator {
    function validateFrame(bytes calldata) external pure returns (bytes4, uint8) {
        return (T.VALIDATION_MAGIC, T.BOTH);
    }
}

contract GasPolicyValidator is IVFrameValidator {
    vFrame public immutable entryPoint;
    address public immutable payer;
    uint256 public immutable expectedMaxCost;
    uint256 public immutable expectedGasPrice;
    uint256 public immutable expectedDeposit;

    constructor(vFrame ep, address payer_, uint256 maxCost, uint256 price, uint256 deposit) {
        entryPoint = ep;
        payer = payer_;
        expectedMaxCost = maxCost;
        expectedGasPrice = price;
        expectedDeposit = deposit;
    }

    function validateFrame(bytes calldata) external view returns (bytes4, uint8) {
        require(msg.sender == address(entryPoint), "caller");
        require(entryPoint.txParam(0x06) == expectedMaxCost, "reservation quote");
        uint256 lower = entryPoint.txParam(0x04);
        uint256 upper = lower + entryPoint.txParam(0x03);
        uint256 price = block.basefee;
        if (price < lower) price = lower;
        if (price > upper) price = upper;
        require(price == expectedGasPrice, "gas price");
        require(entryPoint.deposits(payer) == expectedDeposit - expectedMaxCost, "reservation");
        return (T.VALIDATION_MAGIC, 0);
    }
}

contract AccountFactory {
    function deploy(vFrame entryPoint, address owner, bytes32 salt) external returns (address) {
        return address(new VFrameAccount{salt: salt}(entryPoint, owner));
    }
}

contract VFrameTest is Test {
    vFrame internal entryPoint;
    VFrameAccount internal account;
    VFrameSponsor internal sponsor;
    Probe internal probe;
    uint256 internal constant OWNER_KEY = 0xa11ce;
    uint256 internal constant SPONSOR_KEY = 0xb0b;
    uint256 internal constant MAX_FEE_PER_GAS = 3 gwei;
    address internal constant RELAYER = address(0xbeef);

    function setUp() public {
        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei);
        entryPoint = new vFrame();
        account = new VFrameAccount(entryPoint, vm.addr(OWNER_KEY));
        sponsor = new VFrameSponsor(entryPoint, vm.addr(SPONSOR_KEY));
        probe = new Probe();
        vm.deal(address(this), 20 ether);
        vm.deal(address(account), 5 ether);
        entryPoint.depositTo{value: 2 ether}(address(account));
        entryPoint.depositTo{value: 2 ether}(address(sponsor));
    }

    function _frame(uint8 mode, uint8 flags, address target, bytes memory data)
        internal
        pure
        returns (T.Frame memory)
    {
        if (mode == T.VERIFY) data = abi.encodeCall(IVFrameValidator.validateFrame, (data));
        return T.Frame(mode, flags, target, 200_000, 0, data);
    }

    function _transaction(uint256 count) internal view returns (T.Transaction memory transaction) {
        transaction.sender = address(account);
        transaction.nonceKeys = new uint256[](1);
        transaction.nonce = entryPoint.nonces(address(account), 0);
        transaction.overheadGasLimit = 200_000;
        transaction.maxFeePerGas = MAX_FEE_PER_GAS;
        transaction.maxPriorityFeePerGas = 1 gwei;
        transaction.frames = new T.Frame[](count);
        transaction.signatures = new T.Signature[](count);
        transaction.frames[0] = _frame(T.VERIFY, T.BOTH, address(0), "");
        for (uint256 i = 1; i < count; ++i) {
            transaction.frames[i] =
                _frame(T.SENDER, 0, address(probe), abi.encodeCall(Probe.write, (i)));
        }
    }

    function _sign(T.Transaction memory transaction, uint256 index, uint256 key) internal view {
        transaction.frames[index].data =
            abi.encodeCall(IVFrameValidator.validateFrame, (abi.encode(index)));
        transaction.signatures[index].scheme = T.SECP256K1;
        transaction.signatures[index].signer = vm.addr(key);
        // Metadata is signed: adding another signer re-signs the existing test signers too.
        bytes32 digest = entryPoint.getTransactionHash(transaction);
        for (uint256 i; i < transaction.signatures.length; ++i) {
            T.Signature memory sig = transaction.signatures[i];
            if (sig.scheme != T.SECP256K1) continue;
            uint256 signerKey = sig.signer == vm.addr(OWNER_KEY) ? OWNER_KEY : SPONSOR_KEY;
            (uint8 v, bytes32 r, bytes32 ss) = vm.sign(signerKey, digest);
            transaction.signatures[i].signature = abi.encodePacked(uint8(v - 27), r, ss);
        }
    }

    function _handle(T.Transaction memory transaction) internal returns (T.Result[] memory) {
        vm.prank(RELAYER);
        return entryPoint.handle(transaction);
    }

    function _assertUncharged(uint256 key) internal view {
        assertEq(entryPoint.nonces(address(account), key), 0);
        assertEq(entryPoint.deposits(address(account)), 2 ether);
        assertEq(entryPoint.deposits(RELAYER), 0);
    }

    function _assertCharged(address payer) internal view {
        uint256 charge = entryPoint.deposits(RELAYER);
        assertGt(charge, 0);
        assertEq(entryPoint.deposits(payer) + charge, 2 ether);
    }

    function _assertSettlement(
        T.Transaction memory transaction,
        address payer,
        uint256 beforeDeposit
    ) internal {
        T.GasQuote memory quote = entryPoint.getGasQuote(transaction);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory settlement = logs[logs.length - 1];
        assertEq(settlement.emitter, address(entryPoint));
        assertEq(
            settlement.topics[0],
            keccak256(
                "TransactionHandled(bytes32,address,address,address,uint256,uint256,uint256,uint256)"
            )
        );
        assertEq(settlement.topics[1], entryPoint.getTransactionHash(transaction));
        assertEq(address(uint160(uint256(settlement.topics[3]))), payer);
        (address relayer, uint256 gasUsed, uint256 price, uint256 charge, uint256 refund) =
            abi.decode(settlement.data, (address, uint256, uint256, uint256, uint256));
        assertEq(relayer, RELAYER);
        assertGt(gasUsed, entryPoint.SETTLEMENT_GAS());
        assertLt(gasUsed, quote.gasLimit);
        assertEq(price, quote.gasPrice);
        assertEq(charge, gasUsed * price);
        assertEq(charge + refund, quote.maxCost);
        assertEq(entryPoint.deposits(RELAYER), charge);
        assertEq(entryPoint.deposits(payer), beforeDeposit - charge);
    }

    function test_gasReservationUsesAllLimitsAndRefundsUnusedBudget() public {
        T.Transaction memory transaction = _transaction(2);
        T.GasQuote memory quote = entryPoint.getGasQuote(transaction);
        assertEq(quote.gasLimit, 600_000);
        assertEq(quote.maxCost, 600_000 * (MAX_FEE_PER_GAS + 1 gwei));
        assertEq(quote.gasPrice, 3 gwei);
        _sign(transaction, 0, OWNER_KEY);
        vm.recordLogs();
        _handle(transaction);
        _assertSettlement(transaction, address(account), 2 ether);
        assertLt(entryPoint.deposits(RELAYER), quote.maxCost);
    }

    function test_payerReservationIsVisibleDuringExecutionAndToValidators() public {
        T.Transaction memory transaction = _transaction(3);
        T.GasQuote memory quote = entryPoint.getGasQuote(transaction);
        GasPolicyValidator policy = new GasPolicyValidator(
            entryPoint, address(account), quote.maxCost, quote.gasPrice, 2 ether
        );
        transaction.frames[1] = _frame(T.VERIFY, 0, address(policy), "");
        _sign(transaction, 0, OWNER_KEY);
        _handle(transaction);
        _assertCharged(address(account));
    }

    function test_sponsorReceivesUnusedReservationRefund() public {
        T.Transaction memory transaction = _transaction(3);
        transaction.frames[0].flags = T.EXECUTION;
        transaction.frames[1] = _frame(T.VERIFY, T.PAYMENT, address(sponsor), "");
        _sign(transaction, 0, OWNER_KEY);
        _sign(transaction, 1, SPONSOR_KEY);
        vm.recordLogs();
        _handle(transaction);
        _assertSettlement(transaction, address(sponsor), 2 ether);
        assertEq(entryPoint.deposits(address(account)), 2 ether);
    }

    function test_exactReservationSufficesAndUnusedFundsReturnToPayer() public {
        T.Transaction memory transaction = _transaction(2);
        uint256 reservation = entryPoint.getGasQuote(transaction).maxCost;
        vm.prank(vm.addr(OWNER_KEY));
        account.withdrawDeposit(payable(address(this)), 2 ether - reservation);
        _sign(transaction, 0, OWNER_KEY);
        vm.recordLogs();
        _handle(transaction);
        _assertSettlement(transaction, address(account), reservation);
        assertGt(entryPoint.deposits(address(account)), 0);
    }

    function test_zeroPricedOperationStillRequiresApprovalAndConsumesNonce() public {
        vm.fee(0);
        vm.txGasPrice(0);
        T.Transaction memory transaction = _transaction(2);
        transaction.maxFeePerGas = 0;
        transaction.maxPriorityFeePerGas = 0;
        _sign(transaction, 0, OWNER_KEY);
        vm.recordLogs();
        _handle(transaction);
        _assertSettlement(transaction, address(account), 2 ether);
        assertEq(entryPoint.deposits(RELAYER), 0);
        assertEq(entryPoint.nonces(address(account), 0), 1);
    }

    function test_baseFeeIsClampedToSignedRangeIndependentOfOuterPrice() public {
        T.Transaction memory transaction = _transaction(2);
        vm.txGasPrice(100 gwei);
        assertEq(entryPoint.getGasQuote(transaction).gasPrice, 3 gwei);
        vm.fee(3.5 gwei);
        assertEq(entryPoint.getGasQuote(transaction).gasPrice, 3.5 gwei);
        vm.fee(5 gwei);
        assertEq(entryPoint.getGasQuote(transaction).gasPrice, 4 gwei);
        vm.txGasPrice(1.5 gwei);
        assertEq(entryPoint.getGasQuote(transaction).gasPrice, 4 gwei);
        vm.txGasPrice(0);
        assertEq(entryPoint.getGasQuote(transaction).gasPrice, 4 gwei);
        _sign(transaction, 0, OWNER_KEY);
        vm.recordLogs();
        _handle(transaction);
        _assertSettlement(transaction, address(account), 2 ether);
    }

    function test_invalidGasParametersAndReservationOverflowAreRejected() public {
        T.Transaction memory transaction = _transaction(1);
        transaction.maxPriorityFeePerGas = type(uint256).max;
        vm.expectRevert(vFrame.InvalidGasParameters.selector);
        _handle(transaction);
        transaction.maxPriorityFeePerGas = 1 gwei;
        transaction.maxFeePerGas = type(uint256).max;
        vm.expectRevert(vFrame.InvalidGasParameters.selector);
        _handle(transaction);
        transaction.maxFeePerGas = MAX_FEE_PER_GAS;
        transaction.overheadGasLimit = uint64(entryPoint.SETTLEMENT_GAS() - 1);
        vm.expectRevert(vFrame.InvalidGasParameters.selector);
        _handle(transaction);
        transaction.overheadGasLimit = uint64(entryPoint.MAX_TRANSACTION_GAS());
        vm.expectRevert(vFrame.InvalidGasParameters.selector);
        _handle(transaction);
        _assertUncharged(0);
    }

    function test_relayerCanAcceptReimbursementBelowBaseFee() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.maxFeePerGas = 0.1 gwei;
        transaction.maxPriorityFeePerGas = 0;
        assertLt(transaction.maxFeePerGas, block.basefee);
        assertEq(entryPoint.getGasQuote(transaction).gasPrice, 0.1 gwei);
        _sign(transaction, 0, OWNER_KEY);
        vm.recordLogs();
        T.Result[] memory results = _handle(transaction);
        assertEq(results[1].status, 1);
        _assertSettlement(transaction, address(account), 2 ether);
    }

    function test_relayerCanAcceptZeroReimbursement() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.maxFeePerGas = 0;
        transaction.maxPriorityFeePerGas = 0;
        _sign(transaction, 0, OWNER_KEY);
        vm.recordLogs();
        T.Result[] memory results = _handle(transaction);
        assertEq(results[1].status, 1);
        _assertSettlement(transaction, address(account), 2 ether);
        assertEq(entryPoint.deposits(RELAYER), 0);
        assertEq(entryPoint.nonces(address(account), 0), 1);
    }

    function test_priorityAllowanceMayExceedThePriceFloor() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.maxFeePerGas = 0;
        transaction.maxPriorityFeePerGas = 2 gwei;
        T.GasQuote memory quote = entryPoint.getGasQuote(transaction);
        assertEq(quote.gasPrice, 1 gwei);
        assertEq(quote.maxCost, quote.gasLimit * 2 gwei);
        _sign(transaction, 0, OWNER_KEY);
        vm.recordLogs();
        _handle(transaction);
        _assertSettlement(transaction, address(account), 2 ether);
    }

    function test_measuredGasCannotExceedSignedAggregateBudget() public {
        T.Transaction memory transaction = _transaction(1);
        transaction.frames[0].gasLimit = 40_000;
        transaction.overheadGasLimit = uint64(entryPoint.SETTLEMENT_GAS());
        _sign(transaction, 0, OWNER_KEY);
        vm.expectPartialRevert(vFrame.GasBudgetExceeded.selector);
        _handle(transaction);
        _assertUncharged(0);
    }

    function test_rolledBackCallsAreChargedAndSkippedBudgetsRefunded() public {
        T.Transaction memory transaction = _transaction(4);
        transaction.frames[1].flags = T.ATOMIC;
        transaction.frames[1].data = abi.encodeCall(Probe.exhaustGas, ());
        transaction.frames[1].gasLimit = 80_000;
        transaction.frames[2].flags = T.ATOMIC;
        transaction.frames[2].gasLimit = 1_000_000;
        transaction.frames[3].gasLimit = 1_000_000;
        _sign(transaction, 0, OWNER_KEY);
        vm.recordLogs();
        T.Result[] memory results = _handle(transaction);
        _assertSettlement(transaction, address(account), 2 ether);
        assertEq(results[1].status, 0);
        assertTrue(results[1].rolledBack);
        assertEq(results[2].status, 2);
        assertEq(results[3].status, 2);
        uint256 gasCharged =
            entryPoint.deposits(RELAYER) / entryPoint.getGasQuote(transaction).gasPrice;
        assertGt(gasCharged, 80_000);
        assertLt(gasCharged, 500_000);
        assertEq(entryPoint.nonces(address(account), 0), 1);
    }

    function test_normalTransactionExecutesAsAccountAndPaysRelayer() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1].value = 1 ether;
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(results[0].status, 1);
        assertEq(results[1].status, 1);
        assertEq(abi.decode(results[1].returnData, (uint256)), 1);
        assertEq(probe.caller(), address(account));
        assertEq(probe.received(), 1 ether);
        assertEq(address(account).balance, 4 ether);
        assertEq(entryPoint.nonces(address(account), 0), 1);
        _assertCharged(address(account));
        assertFalse(entryPoint.isExecuting(address(account)));
    }

    function test_sponsorPaysForAccountWithNoDeposit() public {
        vm.prank(vm.addr(OWNER_KEY));
        account.withdrawDeposit(payable(address(this)), 2 ether);
        T.Transaction memory transaction = _transaction(3);
        transaction.frames[0].flags = T.EXECUTION;
        transaction.frames[1] = _frame(T.VERIFY, T.PAYMENT, address(sponsor), "");
        _sign(transaction, 0, OWNER_KEY);
        _sign(transaction, 1, SPONSOR_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(results[2].status, 1);
        assertEq(entryPoint.deposits(address(account)), 0);
        _assertCharged(address(sponsor));
    }

    function test_defaultCallSeesSeparateCallerAndPreservesReturnData() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1].mode = T.DEFAULT;
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        address router = address(entryPoint.defaultCaller());
        assertEq(entryPoint.defaultCaller().entryPoint(), address(entryPoint));
        assertNotEq(router, address(entryPoint));
        assertNotEq(router, address(account));
        assertEq(probe.caller(), router);
        assertEq(results[1].status, 1);
        assertEq(abi.decode(results[1].returnData, (uint256)), 1);
    }

    function test_defaultCallerRejectsDirectAndNestedRouting() public {
        VFrameDefaultCaller router = entryPoint.defaultCaller();
        bytes memory payload = abi.encodeCall(Probe.write, (999));
        vm.expectRevert(VFrameDefaultCaller.Unauthorized.selector);
        router.executeFrame(address(probe), payload);

        T.Transaction memory transaction = _transaction(3);
        transaction.frames[1] = _frame(
            T.DEFAULT,
            0,
            address(router),
            abi.encodeCall(VFrameDefaultCaller.executeFrame, (address(probe), payload))
        );
        transaction.frames[2] = _frame(
            T.SENDER,
            0,
            address(router),
            abi.encodeCall(VFrameDefaultCaller.executeFrame, (address(probe), payload))
        );
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        for (uint256 i = 1; i < 3; ++i) {
            assertEq(results[i].status, 0);
            assertEq(
                results[i].returnData,
                abi.encodeWithSelector(VFrameDefaultCaller.Unauthorized.selector)
            );
        }
        assertEq(probe.value(), 0);
    }

    function test_defaultZeroTargetStillResolvesToSender() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1] = _frame(T.DEFAULT, 0, address(0), abi.encodeCall(account.owner, ()));
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(results[1].status, 1);
        assertEq(abi.decode(results[1].returnData, (address)), vm.addr(OWNER_KEY));
    }

    function test_defaultFailuresAreBoundedAndLaterFramesContinue() public {
        T.Transaction memory transaction = _transaction(6);
        for (uint256 i = 1; i < 6; ++i) {
            transaction.frames[i].mode = T.DEFAULT;
        }
        transaction.frames[1].data = abi.encodeCall(Probe.fail, ());
        transaction.frames[2].data = abi.encodeCall(Probe.largeReturn, ());
        transaction.frames[3].data = abi.encodeCall(Probe.largeRevert, ());
        transaction.frames[4].data = abi.encodeCall(Probe.exhaustGas, ());
        transaction.frames[4].gasLimit = 30_000;
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(results[1].status, 0);
        assertEq(results[1].returnData, abi.encodeWithSignature("Error(string)", "probe rejected"));
        assertEq(results[2].status, 1);
        assertEq(results[2].returnData.length, 2048);
        assertEq(results[3].status, 0);
        assertEq(results[3].returnData.length, 2048);
        assertEq(results[4].status, 0);
        assertEq(results[5].status, 1);
        assertEq(probe.value(), 5);
        assertEq(probe.caller(), address(entryPoint.defaultCaller()));
        assertEq(entryPoint.nonces(address(account), 0), 1);
        _assertCharged(address(account));
    }

    function test_defaultFramesShareAtomicRollbackWithSenderFrames() public {
        Probe afterBatch = new Probe();
        T.Transaction memory transaction = _transaction(5);
        transaction.frames[1].mode = T.DEFAULT;
        transaction.frames[1].flags = T.ATOMIC;
        transaction.frames[2].flags = T.ATOMIC;
        transaction.frames[2].value = 1 ether;
        transaction.frames[3].mode = T.DEFAULT;
        transaction.frames[3].data = abi.encodeCall(Probe.fail, ());
        transaction.frames[4].mode = T.DEFAULT;
        transaction.frames[4].target = address(afterBatch);
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertTrue(results[1].rolledBack);
        assertTrue(results[2].rolledBack);
        assertEq(results[3].status, 0);
        assertTrue(results[3].rolledBack);
        assertEq(probe.value(), 0);
        assertEq(probe.received(), 0);
        assertEq(address(account).balance, 5 ether);
        assertEq(results[4].status, 1);
        assertEq(afterBatch.value(), 4);
        assertEq(afterBatch.caller(), address(entryPoint.defaultCaller()));
        assertFalse(entryPoint.isExecuting(address(account)));
        assertEq(entryPoint.nonces(address(account), 0), 1);
        _assertCharged(address(account));
    }

    function test_transientContextClearsBetweenOperationsInOneTransaction() public {
        T.Transaction memory first = _transaction(2);
        _sign(first, 0, OWNER_KEY);
        _handle(first);
        assertFalse(entryPoint.isExecuting(address(account)));

        T.Transaction memory second = _transaction(2);
        second.frames[1].mode = T.DEFAULT;
        _sign(second, 0, OWNER_KEY);
        _handle(second);
        assertEq(entryPoint.nonces(address(account), 0), 2);
        _assertCharged(address(account));
        assertEq(probe.caller(), address(entryPoint.defaultCaller()));
        assertFalse(entryPoint.isExecuting(address(account)));
    }

    function test_ownerRotationThroughSenderSelfCall() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1].target = address(0);
        transaction.frames[1].data = abi.encodeCall(VFrameAccount.setOwner, (vm.addr(SPONSOR_KEY)));
        _sign(transaction, 0, OWNER_KEY);
        _handle(transaction);
        assertEq(account.owner(), vm.addr(SPONSOR_KEY));
        T.Transaction memory next = _transaction(2);
        _sign(next, 0, OWNER_KEY);
        vm.expectPartialRevert(vFrame.ValidationFailed.selector);
        _handle(next);
        _sign(next, 0, SPONSOR_KEY);
        _handle(next);
        assertEq(probe.value(), 1);
    }

    function test_invalidSignatureLeavesEverythingUnchanged() public {
        T.Transaction memory transaction = _transaction(2);
        _sign(transaction, 0, SPONSOR_KEY);
        vm.expectPartialRevert(vFrame.ValidationFailed.selector);
        _handle(transaction);
        _assertUncharged(0);
        assertEq(probe.value(), 0);
    }

    function test_replayRejected() public {
        T.Transaction memory transaction = _transaction(2);
        _sign(transaction, 0, OWNER_KEY);
        _handle(transaction);
        vm.expectRevert(
            abi.encodeWithSelector(vFrame.NonceMismatch.selector, 0, uint64(1), uint64(0))
        );
        _handle(transaction);
    }

    function test_signatureBoundToChainAndEntryPoint() public {
        T.Transaction memory transaction = _transaction(2);
        _sign(transaction, 0, OWNER_KEY);
        bytes32 hash = entryPoint.getTransactionHash(transaction);
        vFrame second = new vFrame();
        assertNotEq(second.getTransactionHash(transaction), hash);
        vm.chainId(block.chainid + 1);
        assertNotEq(entryPoint.getTransactionHash(transaction), hash);
        vm.expectPartialRevert(vFrame.InvalidSignature.selector);
        _handle(transaction);
        _assertUncharged(0);
    }

    function test_signedExecutionAndFeeCannotBeChanged() public {
        T.Transaction memory transaction = _transaction(2);
        _sign(transaction, 0, OWNER_KEY);
        transaction.frames[1].data = abi.encodeCall(Probe.write, (999));
        vm.expectPartialRevert(vFrame.InvalidSignature.selector);
        _handle(transaction);
        transaction.frames[1].data = abi.encodeCall(Probe.write, (1));
        transaction.maxFeePerGas += 1;
        vm.expectPartialRevert(vFrame.InvalidSignature.selector);
        _handle(transaction);
        transaction.maxFeePerGas -= 1;
        transaction.maxPriorityFeePerGas += 1;
        vm.expectPartialRevert(vFrame.InvalidSignature.selector);
        _handle(transaction);
        transaction.maxPriorityFeePerGas -= 1;
        transaction.overheadGasLimit += 1;
        vm.expectPartialRevert(vFrame.InvalidSignature.selector);
        _handle(transaction);
        _assertUncharged(0);
    }

    function test_lateValidationFailureRollsBackExecutionNonceAndPayment() public {
        T.Transaction memory transaction = _transaction(3);
        transaction.frames[2] = _frame(T.VERIFY, 0, address(sponsor), "");
        _sign(transaction, 0, OWNER_KEY);
        vm.expectPartialRevert(vFrame.ValidationFailed.selector);
        _handle(transaction);
        assertEq(probe.value(), 0);
        _assertUncharged(0);
    }

    function test_validationUsesRawCallAndAllowsStateChanges() public {
        StatefulValidator validator = new StatefulValidator();
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1] = _frame(T.VERIFY, 0, address(validator), "");
        transaction.frames[1].data = abi.encodeCall(StatefulValidator.checkAndWrite, (42));
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory result = _handle(transaction);
        assertEq(result[1].status, 1);
        assertEq(validator.writes(), 42);
        _assertCharged(address(account));
    }

    function test_validatorCanInspectSignedFramesAndPolicyData() public {
        PolicyValidator policy = new PolicyValidator(address(probe));
        T.Transaction memory transaction = _transaction(3);
        transaction.frames[1] = _frame(T.VERIFY, 0, address(policy), "policy");
        _sign(transaction, 0, OWNER_KEY);
        _handle(transaction);
        assertEq(probe.value(), 2);
        transaction.nonce = 1;
        transaction.frames[2].target = address(0x1234);
        _sign(transaction, 0, OWNER_KEY);
        vm.expectPartialRevert(vFrame.ValidationFailed.selector);
        _handle(transaction);
    }

    function test_failedOrdinaryFrameKeepsApprovalAndContinues() public {
        T.Transaction memory transaction = _transaction(3);
        transaction.frames[1].data = abi.encodeCall(Probe.fail, ());
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(results[1].status, 0);
        assertFalse(results[1].rolledBack);
        assertEq(results[2].status, 1);
        assertEq(probe.value(), 2);
        assertEq(entryPoint.nonces(address(account), 0), 1);
        _assertCharged(address(account));
    }

    function test_atomicFailureRollsBackValueAndStorageSkipsSuffixAndContinues() public {
        T.Transaction memory transaction = _transaction(5);
        transaction.frames[1].flags = T.ATOMIC;
        transaction.frames[1].value = 1 ether;
        transaction.frames[2].flags = T.ATOMIC;
        transaction.frames[2].data = abi.encodeCall(Probe.fail, ());
        transaction.frames[4].target = address(0x1234); // Successful transfer to an ordinary EOA.
        transaction.frames[4].data = "";
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(results[1].status, 1);
        assertTrue(results[1].rolledBack);
        assertEq(results[2].status, 0);
        assertTrue(results[2].rolledBack);
        assertEq(results[3].status, 2);
        assertEq(results[4].status, 1);
        assertEq(probe.value(), 0);
        assertEq(probe.received(), 0);
        assertEq(address(account).balance, 5 ether);
        assertEq(entryPoint.nonces(address(account), 0), 1);
        _assertCharged(address(account));
    }

    function test_atomicTerminatorFailureAlsoRollsBackEarlierCalls() public {
        T.Transaction memory transaction = _transaction(3);
        transaction.frames[1].flags = T.ATOMIC;
        transaction.frames[2].data = abi.encodeCall(Probe.fail, ());
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertTrue(results[1].rolledBack);
        assertEq(results[2].status, 0);
        assertEq(probe.value(), 0);
    }

    function test_successfulAtomicGroupKeepsStateAndReturnData() public {
        T.Transaction memory transaction = _transaction(3);
        transaction.frames[1].flags = T.ATOMIC;
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(probe.value(), 2);
        assertEq(abi.decode(results[1].returnData, (uint256)), 1);
        assertEq(abi.decode(results[2].returnData, (uint256)), 2);
        assertFalse(results[1].rolledBack);
    }

    function test_keyedNoncesAreConsumedTogetherAndIndependent() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.nonceKeys = new uint256[](2);
        transaction.nonceKeys[0] = 5;
        transaction.nonceKeys[1] = 9;
        _sign(transaction, 0, OWNER_KEY);
        _handle(transaction);
        assertEq(entryPoint.nonces(address(account), 0), 0);
        assertEq(entryPoint.nonces(address(account), 5), 1);
        assertEq(entryPoint.nonces(address(account), 9), 1);
        transaction.nonceKeys[0] = 7;
        _sign(transaction, 0, OWNER_KEY);
        vm.expectPartialRevert(vFrame.NonceMismatch.selector);
        _handle(transaction);
        assertEq(entryPoint.nonces(address(account), 7), 0);
        transaction.nonceKeys = new uint256[](1);
        transaction.nonceKeys[0] = 7;
        _sign(transaction, 0, OWNER_KEY);
        _handle(transaction);
        assertEq(entryPoint.nonces(address(account), 7), 1);
    }

    function test_defaultCallCannotInvokeUnapprovedAccountExecutionAdapter() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1] = transaction.frames[0];
        transaction.frames[0] = _frame(
            T.DEFAULT,
            0,
            address(account),
            abi.encodeCall(
                IVFrameAccount.executeFrame, (address(probe), 0, abi.encodeCall(Probe.write, (999)))
            )
        );
        _sign(transaction, 1, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(results[0].status, 0);
        assertEq(results[1].status, 1);
        assertEq(probe.value(), 0);
    }

    function test_directAdapterAndBatchCallsAreForbidden() public {
        vm.expectRevert(VFrameAccount.Unauthorized.selector);
        account.executeFrame(address(probe), 0, abi.encodeCall(Probe.write, (1)));
        T.Transaction memory transaction = _transaction(2);
        vm.expectRevert(vFrame.OnlySelf.selector);
        entryPoint.executeGroup(address(account), transaction.frames, 1, 1);
        vm.expectRevert(VFrameAccount.Unauthorized.selector);
        account.setOwner(address(this));
    }

    function test_defaultCallsCannotReachEntryPointSelfOnlyFunctions() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1] = _frame(T.DEFAULT, 0, address(entryPoint), "");
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidFrame.selector, 1));
        _handle(transaction);
    }

    function test_reentryDuringExecutionIsRejected() public {
        T.Transaction memory nested = _transaction(1);
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1].data =
            abi.encodeCall(Probe.reenter, (entryPoint, abi.encodeCall(vFrame.handle, (nested))));
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(results[1].status, 1);
        assertFalse(probe.reentrySucceeded());
        assertEq(entryPoint.nonces(address(account), 0), 1);
    }

    function test_outOfGasTargetFailsOnlyItsFrame() public {
        T.Transaction memory transaction = _transaction(3);
        transaction.frames[1].data = abi.encodeCall(Probe.exhaustGas, ());
        transaction.frames[1].gasLimit = 30_000;
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(results[1].status, 0);
        assertEq(results[2].status, 1);
        assertEq(probe.value(), 2);
    }

    function test_copiedReturnDataIsBounded() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1].data = abi.encodeCall(Probe.largeReturn, ());
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertEq(results[1].status, 1);
        assertEq(results[1].returnData.length, 2048);
    }

    function test_relayerCanWithdrawOnlyItsCredit() public {
        T.Transaction memory transaction = _transaction(1);
        _sign(transaction, 0, OWNER_KEY);
        _handle(transaction);
        uint256 before = RELAYER.balance;
        uint256 credit = entryPoint.deposits(RELAYER);
        assertGt(credit, 0);
        vm.prank(RELAYER);
        entryPoint.withdrawTo(payable(RELAYER), credit);
        assertEq(RELAYER.balance, before + credit);
        assertEq(entryPoint.deposits(RELAYER), 0);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(vFrame.InsufficientDeposit.selector, RELAYER));
        entryPoint.withdrawTo(payable(RELAYER), 1);
    }

    function test_missingExecutionApprovalRejectsSenderFrame() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[0].flags = 0;
        _sign(transaction, 0, OWNER_KEY);
        vm.expectRevert(abi.encodeWithSelector(vFrame.MissingExecutionApproval.selector, 1));
        _handle(transaction);
        _assertUncharged(0);
    }

    function test_sponsorCannotConsumeAnotherAccountsNonce() public {
        T.Transaction memory transaction = _transaction(1);
        transaction.frames[0] = _frame(T.VERIFY, T.PAYMENT, address(sponsor), "");
        _sign(transaction, 0, SPONSOR_KEY);
        vm.expectRevert(abi.encodeWithSelector(vFrame.MissingExecutionApproval.selector, 0));
        _handle(transaction);
        _assertUncharged(0);

        transaction.nonceKeys[0] = 42;
        _sign(transaction, 0, SPONSOR_KEY);
        vm.expectRevert(abi.encodeWithSelector(vFrame.MissingExecutionApproval.selector, 0));
        _handle(transaction);
        _assertUncharged(42);
        assertEq(entryPoint.deposits(address(sponsor)), 2 ether);
    }

    function test_paymentRequiresPriorOrCombinedExecutionApproval() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[0] = _frame(T.VERIFY, T.PAYMENT, address(sponsor), "");
        transaction.frames[1] = _frame(T.VERIFY, T.EXECUTION, address(account), "");
        _sign(transaction, 0, SPONSOR_KEY);
        _sign(transaction, 1, OWNER_KEY);
        vm.expectRevert(abi.encodeWithSelector(vFrame.MissingExecutionApproval.selector, 0));
        _handle(transaction);
        _assertUncharged(0);
        assertEq(entryPoint.deposits(address(sponsor)), 2 ether);
    }

    function test_insufficientOuterGasDoesNotConsumeNonceOrFee() public {
        T.Transaction memory transaction = _transaction(2);
        _sign(transaction, 0, OWNER_KEY);
        vm.prank(RELAYER);
        (bool success, bytes memory reason) =
            address(entryPoint).call{gas: 250_000}(abi.encodeCall(vFrame.handle, (transaction)));
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(vFrame.InsufficientOuterGas.selector));
        _assertUncharged(0);
        assertEq(probe.value(), 0);
    }

    function test_missingPaymentRollsBackBody() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[0].flags = T.EXECUTION;
        _sign(transaction, 0, OWNER_KEY);
        vm.expectRevert(vFrame.MissingPaymentApproval.selector);
        _handle(transaction);
        assertEq(probe.value(), 0);
        _assertUncharged(0);
    }

    function test_duplicateApprovalRollsBackDepositAndNonce() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1] = transaction.frames[0];
        _sign(transaction, 0, OWNER_KEY);
        _sign(transaction, 1, OWNER_KEY);
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidApproval.selector, 1));
        _handle(transaction);
        _assertUncharged(0);
    }

    function test_scopeEscalationIsRejected() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1] = _frame(T.VERIFY, T.PAYMENT, address(new BadScopeValidator()), "");
        transaction.frames[0].flags = T.EXECUTION;
        _sign(transaction, 0, OWNER_KEY);
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidApproval.selector, 1));
        _handle(transaction);
        _assertUncharged(0);
    }

    function test_insufficientFundsRejectsPrefunding() public {
        T.Transaction memory transaction = _transaction(1);
        transaction.maxFeePerGas = 10 ether;
        _sign(transaction, 0, OWNER_KEY);
        vm.expectPartialRevert(vFrame.ValidationFailed.selector);
        _handle(transaction);
        _assertUncharged(0);
    }

    function test_deadlineIsInclusiveAndThenExpires() public {
        T.Transaction memory transaction = _transaction(1);
        transaction.validUntil = 100;
        _sign(transaction, 0, OWNER_KEY);
        vm.warp(100);
        _handle(transaction);
        transaction.nonce = 1;
        _sign(transaction, 0, OWNER_KEY);
        vm.warp(101);
        vm.expectRevert(vFrame.InvalidTransaction.selector);
        _handle(transaction);
    }

    function test_malformedNonceSetsAreRejected() public {
        T.Transaction memory transaction = _transaction(1);
        transaction.nonceKeys = new uint256[](2);
        transaction.nonceKeys[0] = 4;
        transaction.nonceKeys[1] = 4;
        vm.expectRevert(vFrame.InvalidTransaction.selector);
        _handle(transaction);
        transaction.nonceKeys[1] = 3;
        vm.expectRevert(vFrame.InvalidTransaction.selector);
        _handle(transaction);
        transaction.nonceKeys[0] = 0;
        vm.expectRevert(vFrame.InvalidTransaction.selector);
        _handle(transaction);
        transaction.nonceKeys = new uint256[](0);
        vm.expectRevert(vFrame.InvalidTransaction.selector);
        _handle(transaction);
        transaction.nonceKeys = new uint256[](17);
        vm.expectRevert(vFrame.InvalidTransaction.selector);
        _handle(transaction);
    }

    function test_invalidModesFlagsAndBatchBoundariesAreRejected() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[1].mode = 3;
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidFrame.selector, 1));
        _handle(transaction);
        transaction.frames[1].mode = T.SENDER;
        transaction.frames[1].flags = T.ATOMIC;
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidFrame.selector, 1));
        _handle(transaction);
        transaction.frames[1].flags = 8;
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidFrame.selector, 1));
        _handle(transaction);
        transaction.frames[1].flags = T.EXECUTION;
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidFrame.selector, 1));
        _handle(transaction);
    }

    function test_noValueInDefaultOrVerify() public {
        T.Transaction memory transaction = _transaction(2);
        transaction.frames[0].value = 1;
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidFrame.selector, 0));
        _handle(transaction);
        transaction.frames[0].value = 0;
        transaction.frames[1].mode = T.DEFAULT;
        transaction.frames[1].value = 1;
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidFrame.selector, 1));
        _handle(transaction);
    }

    function test_exhaustedNonceRejectedWithoutOverflow() public {
        T.Transaction memory transaction = _transaction(1);
        transaction.nonce = type(uint64).max;
        vm.expectRevert(vFrame.InvalidTransaction.selector);
        _handle(transaction);
    }

    function test_defaultDeployCanCreateAccountBeforeValidation() public {
        AccountFactory factory = new AccountFactory();
        bytes32 salt = keccak256("vFrame account");
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(VFrameAccount).creationCode, abi.encode(entryPoint, vm.addr(OWNER_KEY))
            )
        );
        address predicted = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initHash)))
            )
        );
        T.Transaction memory transaction = _transaction(3);
        transaction.sender = predicted;
        transaction.frames[0] = _frame(
            T.DEFAULT,
            0,
            address(factory),
            abi.encodeCall(AccountFactory.deploy, (entryPoint, vm.addr(OWNER_KEY), salt))
        );
        transaction.frames[0].gasLimit = 1_000_000;
        transaction.frames[1] = _frame(T.VERIFY, T.BOTH, address(0), "");
        entryPoint.depositTo{value: entryPoint.getGasQuote(transaction).maxCost}(predicted);
        _sign(transaction, 1, OWNER_KEY);
        _handle(transaction);
        assertGt(predicted.code.length, 0);
        assertEq(probe.caller(), predicted);
        assertEq(entryPoint.nonces(predicted, 0), 1);
    }

    function test_malleableAndMalformedSignaturesFailClosed() public {
        T.Transaction memory transaction = _transaction(1);
        _sign(transaction, 0, OWNER_KEY);
        bytes32 digest = entryPoint.getTransactionHash(transaction);
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(OWNER_KEY, digest);
        uint256 order = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        transaction.signatures[0].signature =
            abi.encodePacked(uint8(v == 27 ? 1 : 0), r, bytes32(order - uint256(ss)));
        vm.expectPartialRevert(vFrame.InvalidSignature.selector);
        _handle(transaction);
        transaction.signatures[0].signature = abi.encodePacked(v, r, ss);
        vm.expectPartialRevert(vFrame.InvalidSignature.selector);
        _handle(transaction);
        transaction.signatures[0].signature = hex"1234";
        vm.expectPartialRevert(vFrame.InvalidSignature.selector);
        _handle(transaction);
        _assertUncharged(0);
    }

    function testFuzz_hashCommitsToValuesGasKeysAndExpiry(uint64 amount) public view {
        T.Transaction memory transaction = _transaction(2);
        bytes32 original = entryPoint.getTransactionHash(transaction);
        // Witnesses alone are deliberately not part of the signed hash.
        transaction.signatures[0].signature = abi.encode(amount);
        assertEq(entryPoint.getTransactionHash(transaction), original);
        transaction.frames[1].value = uint256(amount) + 1;
        assertNotEq(entryPoint.getTransactionHash(transaction), original);
        transaction.frames[1].value = 0;
        transaction.frames[1].gasLimit += 1;
        assertNotEq(entryPoint.getTransactionHash(transaction), original);
        transaction.frames[1].gasLimit -= 1;
        transaction.nonceKeys[0] = uint256(amount) + 1;
        assertNotEq(entryPoint.getTransactionHash(transaction), original);
        transaction.nonceKeys[0] = 0;
        transaction.validUntil = 1;
        assertNotEq(entryPoint.getTransactionHash(transaction), original);
    }

    function testFuzz_atomicRollbackKeepsNonceAndFee(uint128 nextValue, uint96 sent) public {
        sent = uint96(bound(sent, 0, 5 ether));
        T.Transaction memory transaction = _transaction(3);
        transaction.frames[1].flags = T.ATOMIC;
        transaction.frames[1].value = sent;
        transaction.frames[1].data = abi.encodeCall(Probe.write, (uint256(nextValue)));
        transaction.frames[2].data = abi.encodeCall(Probe.fail, ());
        _sign(transaction, 0, OWNER_KEY);
        T.Result[] memory results = _handle(transaction);
        assertTrue(results[1].rolledBack);
        assertEq(probe.value(), 0);
        assertEq(address(account).balance, 5 ether);
        assertEq(entryPoint.nonces(address(account), 0), 1);
        _assertCharged(address(account));
    }

    receive() external payable {}
}
