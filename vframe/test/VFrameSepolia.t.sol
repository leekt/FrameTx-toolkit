// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {vFrame} from "../src/vFrame.sol";
import {VFrameAccountFactory} from "../src/VFrameAccountFactory.sol";
import {VFrameTypes as T, IVFrameValidator} from "../src/IVFrame.sol";

interface IERC20Demo {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IRouterDemo {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
    function unwrapWETH9(uint256, address) external payable;
    function factory() external view returns (address);
}

interface IPoolFactoryDemo {
    function getPool(address, address, uint24) external view returns (address);
}

interface IQuoterDemo {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(Params calldata)
        external
        returns (uint256, uint160, uint32, uint256);
}

/// @dev Optional live fork test: no testnet transactions or real balances are changed.
contract VFrameSepoliaTest is Test {
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
    uint256 constant KEY = 123;
    vFrame ep;
    address sender;
    address recipient;
    uint256 minimum;
    uint256 recipientBefore;
    address accountFactory;
    address pool;

    function fixture(uint256 amount) internal returns (T.Transaction memory t) {
        string memory rpc = vm.envOr("SEPOLIA_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return t;
        }
        vm.createSelectFork(rpc);
        ep = new vFrame();
        VFrameAccountFactory factory = new VFrameAccountFactory(ep);
        accountFactory = address(factory);
        pool = IPoolFactoryDemo(IRouterDemo(ROUTER).factory()).getPool(USDC, WETH, 3000);
        sender = factory.getAddress(vm.addr(KEY), bytes32(0));
        recipient = makeAddr("recipient");
        recipientBefore = recipient.balance;
        vm.deal(sender, 1 ether);
        deal(USDC, sender, amount);
        (uint256 quoted,,,) = IQuoterDemo(QUOTER)
            .quoteExactInputSingle(IQuoterDemo.Params(USDC, WETH, amount, 3000, 0));
        minimum = quoted * 99 / 100;
        require(minimum > 0, "Pool has no quote");
        t.sender = sender;
        t.nonceKeys = new uint256[](1);
        t.overheadGasLimit = 250_000;
        t.maxFeePerGas = block.basefee * 2 + 1 gwei;
        t.maxPriorityFeePerGas = 1 gwei;
        vm.txGasPrice(block.basefee + 1 gwei);
        t.frames = new T.Frame[](6);
        t.frames[0] = T.Frame(
            0,
            0,
            address(factory),
            1_000_000,
            0,
            abi.encodeCall(factory.createAccount, (vm.addr(KEY), bytes32(0)))
        );
        t.frames[1] = T.Frame(
            1, 3, address(0), 65_000, 0, abi.encodeCall(IVFrameValidator.validateFrame, (bytes("")))
        );
        t.frames[2] =
            T.Frame(2, 4, USDC, 60_000, 0, abi.encodeCall(IERC20Demo.approve, (ROUTER, amount)));
        t.frames[3] = T.Frame(
            2,
            4,
            ROUTER,
            200_000,
            0,
            abi.encodeCall(
                IRouterDemo.exactInputSingle,
                (IRouterDemo.ExactInputSingleParams(USDC, WETH, 3000, ROUTER, amount, minimum, 0))
            )
        );
        t.frames[4] = T.Frame(
            2, 4, ROUTER, 45_000, 0, abi.encodeCall(IRouterDemo.unwrapWETH9, (minimum, sender))
        );
        t.frames[5] = T.Frame(2, 0, recipient, 40_000, minimum, "");
        t.signatures = new T.Signature[](1);
        t.signatures[0] = T.Signature(1, vm.addr(KEY), bytes32(0), "");
    }

    function sign(T.Transaction memory t) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, ep.getTransactionHash(t));
        t.signatures[0].signature = abi.encodePacked(v - 27, r, s);
        // Fixture funding and quotes must not make execution cheaper than a fresh transaction.
        vm.cool(address(ep.defaultCaller()));
        vm.cool(address(ep));
        vm.cool(accountFactory);
        vm.cool(sender);
        vm.cool(USDC);
        vm.cool(WETH);
        vm.cool(ROUTER);
        vm.cool(pool);
    }

    function testSepoliaCircleUSDCToETHAndSpend() public {
        T.Transaction memory t = fixture(1_000_000);
        sign(t);
        T.Result[] memory results = ep.handle(t);
        for (uint256 i; i < 6; i++) {
            assertEq(results[i].status, 1);
            assertFalse(results[i].rolledBack);
        }
        assertEq(IERC20Demo(USDC).balanceOf(sender), 0);
        assertEq(recipient.balance, recipientBefore + minimum);
        assertEq(ep.nonces(sender, 0), 1);
    }

    function testSepoliaSwapBeforeApprovalRollsBackGroup() public {
        T.Transaction memory t = fixture(1_000_000);
        (t.frames[2], t.frames[3]) = (t.frames[3], t.frames[2]);
        sign(t);
        T.Result[] memory results = ep.handle(t);
        assertEq(results[2].status, 0);
        assertTrue(results[2].rolledBack);
        assertEq(results[3].status, 2);
        assertEq(IERC20Demo(USDC).balanceOf(sender), 1_000_000);
        assertEq(recipient.balance, recipientBefore);
        assertEq(ep.nonces(sender, 0), 1);
        assertGt(ep.deposits(address(this)), 0);
    }

    function payAfterSwapFixture() internal returns (T.Transaction memory t) {
        return payAfterSwapFixture(1_000_000_000);
    }

    function payAfterSwapFixture(uint256 amount) internal returns (T.Transaction memory t) {
        t = fixture(amount);
        vm.deal(sender, 0);
        t.frames[1].flags = T.EXECUTION;
        t.frames[1].gasLimit = 30_000;
        t.frames[4].flags = 0;
        t.frames[5] = T.Frame(
            T.VERIFY,
            T.PAYMENT,
            address(0),
            65_000,
            0,
            abi.encodeCall(IVFrameValidator.validateFrame, (bytes("")))
        );
    }

    function testSepoliaPayGasAfterSwapWithoutStartingETH() public {
        T.Transaction memory t = payAfterSwapFixture();
        assertEq(sender.balance, 0);
        assertEq(ep.deposits(sender), 0);
        assertGt(minimum, ep.getGasQuote(t).maxCost);
        sign(t);
        T.Result[] memory results = ep.handle(t);
        for (uint256 i; i < results.length; ++i) {
            assertEq(results[i].status, 1);
            assertFalse(results[i].rolledBack);
        }
        assertEq(IERC20Demo(USDC).balanceOf(sender), 0);
        assertGt(sender.balance, 0);
        assertGt(ep.deposits(sender), 0);
        assertGt(ep.deposits(address(this)), 0);
        assertEq(ep.nonces(sender, 0), 1);
    }

    function testSepoliaPaymentBeforeSwapCannotUseFutureETH() public {
        T.Transaction memory t = payAfterSwapFixture();
        // Keep the execution VERIFY first, but move the payment VERIFY before the swap.
        T.Frame memory payment = t.frames[5];
        for (uint256 i = 5; i > 2; --i) {
            t.frames[i] = t.frames[i - 1];
        }
        t.frames[2] = payment;
        sign(t);
        vm.expectRevert();
        ep.handle(t);
        assertEq(sender.balance, 0);
        assertEq(sender.code.length, 0);
        assertEq(IERC20Demo(USDC).balanceOf(sender), 1_000_000_000);
        assertEq(ep.nonces(sender, 0), 0);
    }

    function testSepoliaExistingAccountUsesReducedDeploymentBudget() public {
        T.Transaction memory t = payAfterSwapFixture();
        VFrameAccountFactory(accountFactory).createAccount(vm.addr(KEY), bytes32(0));
        t.frames[0].gasLimit = 25_000;
        assertEq(ep.getGasQuote(t).gasLimit, 675_000);
        sign(t);
        T.Result[] memory results = ep.handle(t);
        for (uint256 i; i < results.length; ++i) {
            assertEq(results[i].status, 1);
            assertFalse(results[i].rolledBack);
        }
        assertEq(IERC20Demo(USDC).balanceOf(sender), 0);
        assertGt(sender.balance, 0);
        assertEq(ep.nonces(sender, 0), 1);
    }

    function testSepoliaTwentyUSDCWithAffordablePriceAndNoETHTopup() public {
        T.Transaction memory t = payAfterSwapFixture(20_000_000);
        uint256 gasLimit = ep.getGasQuote(t).gasLimit;
        t.maxFeePerGas = minimum * 10_000 / (gasLimit * 12_500);
        t.maxPriorityFeePerGas = 0;
        assertLt(t.maxFeePerGas, block.basefee);
        assertEq(sender.balance, 0);
        assertEq(ep.deposits(sender), 0);
        assertLe((ep.getGasQuote(t).maxCost * 12_500 + 9_999) / 10_000, minimum);
        sign(t);
        T.Result[] memory results = ep.handle(t);
        for (uint256 i; i < results.length; ++i) {
            assertEq(results[i].status, 1);
            assertFalse(results[i].rolledBack);
        }
        assertEq(IERC20Demo(USDC).balanceOf(sender), 0);
        assertGt(sender.balance, 0);
        assertGt(ep.deposits(address(this)), 0);
        assertEq(ep.nonces(sender, 0), 1);
    }
}
