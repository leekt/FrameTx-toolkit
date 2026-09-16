// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {vFrame} from "../src/vFrame.sol";
import {VFrameAccount} from "../src/VFrameAccount.sol";
import {VFrameAccountFactory} from "../src/VFrameAccountFactory.sol";
import {VFrameSponsor} from "../src/VFrameSponsor.sol";
import {VFrameTypes as T, IVFrameValidator} from "../src/IVFrame.sol";

contract RevertingDefaultApprover {
    function approveThenRevert(vFrame ep) external {
        ep.approveExecution();
        revert("discard approval");
    }
}

contract VFrameFactoryTest is Test {
    vFrame ep;
    VFrameAccountFactory factory;
    uint256 constant KEY = 123;
    uint256 constant P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    bytes32 constant SALT = bytes32(uint256(7));

    function setUp() public {
        ep = new vFrame();
        factory = new VFrameAccountFactory(ep);
        vm.deal(address(this), 10 ether);
        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei);
    }

    function transaction(address owner) internal view returns (T.Transaction memory t) {
        t.sender = factory.getAddress(owner, SALT);
        t.nonceKeys = new uint256[](1);
        t.overheadGasLimit = 400_000;
        t.maxFeePerGas = 3 gwei;
        t.maxPriorityFeePerGas = 1 gwei;
        t.frames = new T.Frame[](3);
        t.frames[0] = T.Frame(
            T.DEFAULT,
            0,
            address(factory),
            1_000_000,
            0,
            abi.encodeCall(factory.createAccount, (owner, SALT))
        );
        t.frames[1] = T.Frame(
            T.VERIFY,
            T.BOTH,
            address(0),
            250_000,
            0,
            abi.encodeCall(IVFrameValidator.validateFrame, (bytes("")))
        );
        t.frames[2] = T.Frame(T.SENDER, 0, address(0xbeef), 100_000, 0.01 ether, "");
        t.signatures = new T.Signature[](1);
        t.signatures[0] = T.Signature(T.SECP256K1, owner, bytes32(0), "");
    }

    function sign(T.Transaction memory t) internal view {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, ep.getTransactionHash(t));
        t.signatures[0].signature = abi.encodePacked(v - 27, r, s);
    }

    function defaultApprovalTransaction(address owner)
        internal
        view
        returns (T.Transaction memory t)
    {
        t = transaction(owner);
        T.Frame memory deploy = t.frames[0];
        T.Frame memory pay = t.frames[1];
        T.Frame memory spend = t.frames[2];
        pay.flags = T.PAYMENT;
        t.frames = new T.Frame[](4);
        t.frames[0] = deploy;
        t.frames[1] = T.Frame(
            T.DEFAULT,
            T.EXECUTION,
            address(0),
            250_000,
            0,
            abi.encodeCall(VFrameAccount.approveExecution, (uint256(0)))
        );
        t.frames[2] = spend;
        t.frames[3] = pay;
    }

    function testDefaultApprovalAllowsSenderBeforeSoleFinalVerify() public {
        T.Transaction memory t = defaultApprovalTransaction(vm.addr(KEY));
        vm.deal(t.sender, 1 ether);
        sign(t);
        T.Result[] memory results = ep.handle(t);
        for (uint256 i; i < results.length; ++i) {
            assertEq(results[i].status, 1);
        }
        assertEq(address(0xbeef).balance, 0.01 ether);
        assertEq(ep.nonces(t.sender, 0), 1);
    }

    function testDefaultApprovalSupportsP256() public {
        (address owner,,) = p256Owner();
        T.Transaction memory t = defaultApprovalTransaction(owner);
        vm.deal(t.sender, 1 ether);
        signP256(t);
        T.Result[] memory results = ep.handle(t);
        for (uint256 i; i < results.length; ++i) {
            assertEq(results[i].status, 1);
        }
    }

    function testDefaultApprovalRejectsAnotherSigner() public {
        T.Transaction memory t = defaultApprovalTransaction(vm.addr(456));
        t.signatures[0].signer = vm.addr(KEY);
        vm.deal(t.sender, 1 ether);
        sign(t);
        vm.expectRevert(abi.encodeWithSelector(vFrame.MissingExecutionApproval.selector, 2));
        ep.handle(t);
        assertEq(t.sender.code.length, 0);
        assertEq(ep.nonces(t.sender, 0), 0);
    }

    function testDefaultApprovalNeedsDeclaredScopeAndResetsBetweenOperations() public {
        T.Transaction memory t = defaultApprovalTransaction(vm.addr(KEY));
        vm.deal(t.sender, 1 ether);
        sign(t);
        ep.handle(t);
        t.nonce = 1;
        t.frames[1].flags = 0;
        sign(t);
        vm.expectRevert(abi.encodeWithSelector(vFrame.MissingExecutionApproval.selector, 2));
        ep.handle(t);
        assertEq(ep.nonces(t.sender, 0), 1);
        assertEq(address(0xbeef).balance, 0.01 ether);
    }

    function testDefaultApprovalRejectsCallsOutsideDispatch() public {
        VFrameAccount account = factory.createAccount(vm.addr(KEY), SALT);
        vm.expectRevert(VFrameAccount.Unauthorized.selector);
        account.approveExecution(0);
        vm.expectRevert(vFrame.NoActiveFrame.selector);
        ep.approveExecution();
    }

    function testDefaultApprovalRollsBackWithItsCall() public {
        T.Transaction memory t = defaultApprovalTransaction(vm.addr(KEY));
        RevertingDefaultApprover approver = new RevertingDefaultApprover();
        T.Frame memory spend = t.frames[2];
        T.Frame memory pay = t.frames[3];
        t.sender = address(approver);
        t.frames = new T.Frame[](3);
        t.frames[0] = T.Frame(
            T.DEFAULT,
            T.EXECUTION,
            address(approver),
            250_000,
            0,
            abi.encodeCall(approver.approveThenRevert, (ep))
        );
        t.frames[1] = spend;
        t.frames[2] = pay;
        sign(t);
        vm.expectRevert(abi.encodeWithSelector(vFrame.MissingExecutionApproval.selector, 1));
        ep.handle(t);
    }

    function p256Owner() internal pure returns (address owner, uint256 x, uint256 y) {
        (x, y) = vm.publicKeyP256(KEY);
        owner = address(uint160(uint256(keccak256(abi.encode(x, y)))));
    }

    function signP256(T.Transaction memory t) internal view {
        (, uint256 x, uint256 y) = p256Owner();
        t.signatures[0].scheme = T.P256;
        bytes32 digest = t.signatures[0].message;
        if (digest == bytes32(0)) digest = ep.getTransactionHash(t);
        (bytes32 r, bytes32 s) = vm.signP256(KEY, digest);
        if (uint256(s) > P256_N / 2) s = bytes32(P256_N - uint256(s));
        t.signatures[0].signature = abi.encode(r, s, x, y);
    }

    function testFactoryIdempotentAndOwnerBound() public {
        address owner = vm.addr(KEY);
        address predicted = factory.getAddress(owner, SALT);
        vm.deal(predicted, 1 ether);
        vm.prank(address(0xbad));
        VFrameAccount account = factory.createAccount(owner, SALT);
        assertEq(address(account), predicted);
        assertEq(address(factory.createAccount(owner, SALT)), predicted);
        assertEq(account.owner(), owner);
        assertEq(address(account.entryPoint()), address(ep));
        assertEq(predicted.balance, 1 ether);
        assertTrue(factory.getAddress(address(0xbad), SALT) != predicted);
    }

    function testRejectZeroOwner() public {
        vm.expectRevert(VFrameAccount.InvalidOwner.selector);
        factory.createAccount(address(0), SALT);
    }

    function testDeployValidatePrefundAndSpendInOneTransaction() public {
        T.Transaction memory t = transaction(vm.addr(KEY));
        vm.deal(t.sender, 1 ether);
        sign(t);
        uint256 maximum = ep.getGasQuote(t).maxCost;
        T.Result[] memory results = ep.handle(t);
        assertEq(results[0].status, 1);
        assertEq(results[1].status, 1);
        assertEq(results[2].status, 1);
        assertEq(t.sender.balance, 1 ether - maximum - 0.01 ether);
        assertEq(address(0xbeef).balance, 0.01 ether);
        assertEq(ep.nonces(t.sender, 0), 1);
        assertEq(ep.deposits(t.sender) + ep.deposits(address(this)), maximum);
    }

    function testOnlyMissingDepositIsPrefunded() public {
        T.Transaction memory t = transaction(vm.addr(KEY));
        uint256 maximum = ep.getGasQuote(t).maxCost;
        uint256 existing = maximum / 2;
        ep.depositTo{value: existing}(t.sender);
        vm.deal(t.sender, 1 ether);
        sign(t);
        ep.handle(t);
        assertEq(t.sender.balance, 1 ether - (maximum - existing) - 0.01 ether);
        assertEq(ep.deposits(t.sender) + ep.deposits(address(this)), maximum);
    }

    function testValidationFailureRollsBackDeploymentAndPrefunding() public {
        T.Transaction memory t = transaction(vm.addr(KEY));
        vm.deal(t.sender, 1 ether);
        // Repeated BOTH approval fails after the first validation has prefunded.
        t.frames[2] = t.frames[1];
        sign(t);
        vm.expectRevert();
        ep.handle(t);
        assertEq(t.sender.code.length, 0);
        assertEq(t.sender.balance, 1 ether);
        assertEq(ep.deposits(t.sender), 0);
        assertEq(ep.nonces(t.sender, 0), 0);
    }

    function testP256AccountDeployAndValidate() public {
        (address owner,,) = p256Owner();
        T.Transaction memory t = transaction(owner);
        vm.deal(t.sender, 1 ether);
        signP256(t);
        ep.handle(t);
        assertEq(VFrameAccount(payable(t.sender)).owner(), owner);
        assertEq(address(0xbeef).balance, 0.01 ether);
    }

    function testP256InvalidSignatureRejectedBeforeDeployment() public {
        (address owner,,) = p256Owner();
        T.Transaction memory t = transaction(owner);
        signP256(t);
        t.signatures[0].signature[0] ^= 0x01;
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidSignature.selector, 0));
        ep.handle(t);
        assertEq(t.sender.code.length, 0);
    }

    function testP256HighSRejected() public {
        (address owner,,) = p256Owner();
        T.Transaction memory t = transaction(owner);
        signP256(t);
        (bytes32 r, uint256 s, bytes32 x, bytes32 y) =
            abi.decode(t.signatures[0].signature, (bytes32, uint256, bytes32, bytes32));
        t.signatures[0].signature = abi.encode(r, P256_N - s, x, y);
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidSignature.selector, 0));
        ep.handle(t);
    }

    function testP256SignerMustMatchPublicKey() public {
        T.Transaction memory t = transaction(vm.addr(KEY));
        signP256(t);
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidSignature.selector, 0));
        ep.handle(t);
    }

    function testP256MalformedLengthRejected() public {
        (address owner,,) = p256Owner();
        T.Transaction memory t = transaction(owner);
        t.signatures[0].scheme = T.P256;
        t.signatures[0].signature = hex"1234";
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidSignature.selector, 0));
        ep.handle(t);
    }

    function testUnsupportedSchemeRejected() public {
        T.Transaction memory t = transaction(vm.addr(KEY));
        t.signatures[0].scheme = 3;
        vm.expectRevert(abi.encodeWithSelector(vFrame.UnsupportedSignatureScheme.selector, 3));
        ep.handle(t);
    }

    function testP256RejectsZeroScalarsAndInvalidPoints() public {
        (address owner,,) = p256Owner();
        T.Transaction memory t = transaction(owner);
        signP256(t);
        (uint256 r, uint256 s, uint256 x, uint256 y) =
            abi.decode(t.signatures[0].signature, (uint256, uint256, uint256, uint256));
        bytes[] memory invalid = new bytes[](4);
        invalid[0] = abi.encode(uint256(0), s, x, y);
        invalid[1] = abi.encode(r, uint256(0), x, y);
        invalid[2] = abi.encode(P256_N, s, x, y);
        invalid[3] = abi.encode(r, s, uint256(0), uint256(0));
        for (uint256 i; i < invalid.length; ++i) {
            t.signatures[0].signature = invalid[i];
            vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidSignature.selector, 0));
            ep.handle(t);
        }
    }

    function testP256AbsentPrecompileFailsClosed() public {
        (address owner,,) = p256Owner();
        T.Transaction memory t = transaction(owner);
        signP256(t);
        vm.mockCall(address(0x100), bytes(""), bytes(""));
        vm.expectRevert(abi.encodeWithSelector(vFrame.InvalidSignature.selector, 0));
        ep.handle(t);
    }

    function testSponsorPrefundsWhileExecutionOnlyAccountDoesNot() public {
        T.Transaction memory t = transaction(vm.addr(KEY));
        VFrameSponsor sponsor = new VFrameSponsor(ep, vm.addr(456));
        vm.deal(address(sponsor), 1 ether);
        t.frames[1].flags = T.EXECUTION;
        t.frames[2] = T.Frame(
            T.VERIFY,
            T.PAYMENT,
            address(sponsor),
            250_000,
            0,
            abi.encodeCall(IVFrameValidator.validateFrame, (abi.encode(uint256(1))))
        );
        t.signatures = new T.Signature[](2);
        t.signatures[0] = T.Signature(T.SECP256K1, vm.addr(KEY), bytes32(0), "");
        t.signatures[1] = T.Signature(T.SECP256K1, vm.addr(456), bytes32(0), "");
        sign(t);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(456, ep.getTransactionHash(t));
        t.signatures[1].signature = abi.encodePacked(v - 27, r, s);
        uint256 maximum = ep.getGasQuote(t).maxCost;
        ep.handle(t);
        assertEq(t.sender.balance, 0);
        assertEq(ep.deposits(t.sender), 0);
        assertEq(address(sponsor).balance, 1 ether - maximum);
        assertEq(ep.deposits(address(sponsor)) + ep.deposits(address(this)), maximum);
    }

    function testExplicitP256DigestVerifiedButDoesNotAuthorizeAccount() public {
        (address owner,,) = p256Owner();
        T.Transaction memory t = transaction(owner);
        t.signatures[0].message = keccak256("explicit digest");
        signP256(t);
        vm.deal(t.sender, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                vFrame.ValidationFailed.selector,
                1,
                abi.encodeWithSelector(VFrameAccount.Unauthorized.selector)
            )
        );
        ep.handle(t);
    }
}
