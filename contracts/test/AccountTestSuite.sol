// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";
import {IFrameAccount} from "../src/accounts/IFrameAccount.sol";

/// Reusable conformance tests for an EIP-8141 account implementation.
///
/// A concrete account test supplies only its deployed address and the canonical
/// signatures needed to satisfy its policy. The suite then proves that the account
/// can occupy each account-side approval role in the standard frame prefixes:
/// self relay (BOTH), sponsored relay (EXECUTION), and paying for another
/// sender (PAYMENT).
///
/// These fixtures execute the validation bytecode and real frame opcodes with a
/// non-zero max cost and a funded intended payer. The synthetic frame context
/// does not model the eventual ETH debit, refund, or nonce transition; those
/// remain transaction-level Anvil assertions.
abstract contract AccountTestSuite is FrameTest {
    address private constant DEFAULT_OTHER_SENDER = address(0xA11CE001);
    address private constant DEFAULT_PAYMASTER_SIGNER = address(0xA11CE002);
    address private constant DEFAULT_CALL_TARGET = address(0xA11CE003);
    uint160 internal constant SUITE_STRANGER_BASE = 0xBAD00000;
    uint256 internal constant SUITE_MAX_COST = 0.25 ether;

    /// The fully initialized account under test.
    function accountUnderTest() internal view virtual returns (address);

    /// Override these only when a subject reserves one of the default fixture
    /// addresses. They must remain distinct from the account under test and
    /// from each other.
    function accountSuiteOtherSender() internal view virtual returns (address) {
        return DEFAULT_OTHER_SENDER;
    }

    function accountSuitePaymasterSigner() internal view virtual returns (address) {
        return DEFAULT_PAYMASTER_SIGNER;
    }

    function accountSuiteCallTarget() internal view virtual returns (address) {
        return DEFAULT_CALL_TARGET;
    }

    /// Synthetic canonical signature hash shared by every context in this
    /// suite. Scheme-specific fixtures such as WebAuthn assertions may override
    /// or consume it when constructing their authorization bytes.
    function accountSuiteSigHash() internal view virtual returns (bytes32) {
        return bytes32(uint256(0x8141));
    }

    /// Signature entries which satisfy this account's policy. Returning full
    /// entries keeps the suite reusable across native protocol schemes and
    /// contract-verified ARBITRARY witnesses such as WebAuthn assertions.
    function accountAuthorizationSignatures()
        internal
        view
        virtual
        returns (IFrameVm.FrameTxSignature[] memory);

    /// Entries known not to satisfy the account policy, used to prove that
    /// selecting the wrong indices cannot borrow valid authorization elsewhere
    /// in the envelope. The default avoids every signer returned by the positive
    /// hook. Override this for policies with additional trusted keys or
    /// non-signer-based authorization that the positive hook does not enumerate.
    function accountUnauthorizedSignatures()
        internal
        view
        virtual
        returns (IFrameVm.FrameTxSignature[] memory unauthorized)
    {
        IFrameVm.FrameTxSignature[] memory authorization = accountAuthorizationSignatures();
        unauthorized = new IFrameVm.FrameTxSignature[](authorization.length);
        for (uint256 i = 0; i < authorization.length; ++i) {
            address stranger = _strangerNotInAuthorization(
                SUITE_STRANGER_BASE + uint160(i + 1), authorization, unauthorized, i
            );
            unauthorized[i] = secpSig(stranger);
        }
    }

    function selected(uint256 a) internal pure returns (uint256[] memory indices) {
        indices = new uint256[](1);
        indices[0] = a;
    }

    function selected(uint256 a, uint256 b) internal pure returns (uint256[] memory indices) {
        indices = new uint256[](2);
        indices[0] = a;
        indices[1] = b;
    }

    function selected(uint256 a, uint256 b, uint256 c)
        internal
        pure
        returns (uint256[] memory indices)
    {
        indices = new uint256[](3);
        indices[0] = a;
        indices[1] = b;
        indices[2] = c;
    }

    /// Encode the shared account ABI explicitly. Keeping this in one helper
    /// prevents a test from silently falling through an account's receive path.
    function validationCalldata(uint256[] memory signatureIndices)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(IFrameAccount.validate.selector, signatureIndices);
    }

    /// A threshold-sized stranger block precedes the account's selected entries.
    /// Thus every positive case reads valid account signatures at shifted,
    /// non-zero indices rather than accidentally depending on signature zero.
    function conformanceSignatures()
        internal
        view
        returns (IFrameVm.FrameTxSignature[] memory signatures, uint256[] memory accountIndices)
    {
        IFrameVm.FrameTxSignature[] memory authorization = accountAuthorizationSignatures();
        IFrameVm.FrameTxSignature[] memory unauthorized = accountUnauthorizedSignatures();
        uint256 n = authorization.length;
        require(n != 0, "suite requires an authorization signature");
        require(unauthorized.length == n, "suite requires matching unauthorized signatures");

        signatures = new IFrameVm.FrameTxSignature[](n * 2);
        accountIndices = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            signatures[i] = unauthorized[i];

            uint256 sigIndex = n + i;
            signatures[sigIndex] = authorization[i];
            accountIndices[i] = sigIndex;
        }
    }

    /// Pick distinct distractor signers which do not collide with any signer
    /// returned by the account's authorization hook. Fixed magic addresses
    /// would make the routing-negative invalid for an account that happened to
    /// trust one of them.
    function _strangerNotInAuthorization(
        uint160 candidate,
        IFrameVm.FrameTxSignature[] memory authorization,
        IFrameVm.FrameTxSignature[] memory signatures,
        uint256 strangerCount
    ) private pure returns (address result) {
        result = address(candidate);
        while (true) {
            bool collision;
            for (uint256 i = 0; i < authorization.length; ++i) {
                if (result == authorization[i].signer) {
                    collision = true;
                    break;
                }
            }
            if (!collision) {
                for (uint256 i = 0; i < strangerCount; ++i) {
                    if (result == signatures[i].signer) {
                        collision = true;
                        break;
                    }
                }
            }
            if (!collision) return result;
            result = address(uint160(result) + 1);
        }
    }

    function strangerIndices() internal view returns (uint256[] memory indices) {
        uint256 signatureCount = accountAuthorizationSignatures().length;
        indices = new uint256[](signatureCount);
        for (uint256 i = 0; i < signatureCount; ++i) {
            indices[i] = i;
        }
    }

    function senderFrame() internal view returns (IFrameVm.FrameTxFrame memory) {
        return IFrameVm.FrameTxFrame({
            mode: MODE_SENDER,
            flags: 0,
            target: accountSuiteCallTarget(),
            gasLimit: 100_000,
            stateGasLimit: 0,
            value: 0,
            data: hex"12345678",
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
    }

    function verifyFrame(address target, uint64 scope, bytes memory data, uint8 status)
        internal
        pure
        returns (IFrameVm.FrameTxFrame memory)
    {
        return IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(scope),
            target: target,
            gasLimit: 200_000,
            stateGasLimit: 0,
            value: 0,
            data: data,
            status: status,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
    }

    function selfPayContext(uint256[] memory signatureIndices)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        address account = accountUnderTest();
        ctx = verifyContext(account, SCOPE_BOTH, accountSuiteSigHash());
        ctx.frames = new IFrameVm.FrameTxFrame[](2);
        ctx.frames[0] = verifyFrame(account, SCOPE_BOTH, validationCalldata(signatureIndices), 0);
        ctx.frames[1] = senderFrame();
        (ctx.signatures,) = conformanceSignatures();
        ctx.maxCost = SUITE_MAX_COST;
        ctx.approvableScopes = SCOPE_BOTH;
    }

    function sponsoredContext(uint256[] memory signatureIndices, address paymaster)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        address account = accountUnderTest();
        ctx = verifyContext(account, SCOPE_EXECUTION, accountSuiteSigHash());
        ctx.frames = new IFrameVm.FrameTxFrame[](3);
        ctx.frames[0] =
            verifyFrame(account, SCOPE_EXECUTION, validationCalldata(signatureIndices), 0);
        ctx.frames[1] = verifyFrame(
            paymaster,
            SCOPE_PAYMENT,
            abi.encodeWithSignature("sponsorTransaction(uint256)", uint256(0)),
            0
        );
        ctx.frames[2] = senderFrame();
        (ctx.signatures,) = conformanceSignatures();
        // Signature zero documents the later pay frame's own authorization; it
        // remains unselected by, and untrusted by, the account under test.
        ctx.signatures[0] = secpSig(accountSuitePaymasterSigner());
        ctx.maxCost = SUITE_MAX_COST;
        ctx.approvableScopes = SCOPE_EXECUTION;
    }

    function paysOtherSenderContext(uint256[] memory signatureIndices)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        address account = accountUnderTest();
        ctx = verifyContext(account, SCOPE_PAYMENT, accountSuiteSigHash());
        address otherSender = accountSuiteOtherSender();
        ctx.sender = otherSender;
        ctx.frameIndex = 1;
        ctx.frames = new IFrameVm.FrameTxFrame[](3);
        ctx.frames[0] = verifyFrame(
            otherSender,
            SCOPE_EXECUTION,
            abi.encodeWithSelector(IFrameAccount.validate.selector, selected(0)),
            1
        );
        ctx.frames[1] = verifyFrame(account, SCOPE_PAYMENT, validationCalldata(signatureIndices), 0);
        ctx.frames[2] = senderFrame();
        (ctx.signatures,) = conformanceSignatures();
        // Make the already-successful sender VERIFY frame internally coherent.
        // This entry is not selected by the subject account's payment frame.
        ctx.signatures[0] = secpSig(otherSender);
        ctx.maxCost = SUITE_MAX_COST;
        ctx.approvableScopes = SCOPE_PAYMENT;
    }

    function test_accountSuite_verifiesAndPaysForItself() public {
        vm.deal(accountUnderTest(), SUITE_MAX_COST);
        (, uint256[] memory accountIndices) = conformanceSignatures();
        IFrameVm.FrameTx memory ctx = selfPayContext(accountIndices);
        assertEq(ctx.frames[0].flags, SCOPE_BOTH, "self frame must permit exactly BOTH");

        ctx.approvableScopes = SCOPE_PAYMENT;
        assertRefusesFrame(
            accountUnderTest(), ctx, "self relay must request BOTH, not PAYMENT only"
        );
        ctx = selfPayContext(accountIndices);
        ctx.approvableScopes = SCOPE_EXECUTION;
        assertRefusesFrame(
            accountUnderTest(), ctx, "self relay must request BOTH, not EXECUTION only"
        );
        ctx = selfPayContext(accountIndices);
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(accountUnderTest(), ctx, "self relay must execute APPROVE(BOTH)");

        ctx = selfPayContext(accountIndices);
        assertEq(ctx.approvableScopes, SCOPE_BOTH, "host scope must be exactly BOTH");
        assertApprovesFrame(accountUnderTest(), ctx, "account must verify and pay for itself");
    }

    function test_accountSuite_verifiesWhileLaterPaymasterPays() public {
        address paymaster = deployAccountWithArgs(
            "SponsoringPaymaster", abi.encode(accountSuitePaymasterSigner(), SUITE_MAX_COST)
        );
        vm.deal(accountUnderTest(), 0);
        vm.deal(paymaster, SUITE_MAX_COST);
        (, uint256[] memory accountIndices) = conformanceSignatures();
        IFrameVm.FrameTx memory ctx = sponsoredContext(accountIndices, paymaster);
        assertEq(
            ctx.frames[0].flags, SCOPE_EXECUTION, "account frame must permit exactly EXECUTION"
        );
        assertEq(
            ctx.frames[1].flags, SCOPE_PAYMENT, "later paymaster frame must permit exactly PAYMENT"
        );

        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(
            accountUnderTest(), ctx, "sponsored relay must execute APPROVE(EXECUTION)"
        );
        ctx = sponsoredContext(accountIndices, paymaster);
        assertEq(ctx.approvableScopes, SCOPE_EXECUTION, "host scope must be exactly EXECUTION");
        assertApprovesFrame(
            accountUnderTest(), ctx, "account must verify execution while a later paymaster pays"
        );

        // The synthetic host context does not persist sender_approved across
        // calls. Exercising the same fixture's second frame still proves the
        // configured paymaster reaches the complementary PAYMENT approval.
        ctx.frameIndex = 1;
        ctx.frames[0].status = 1;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(paymaster, ctx, "paymaster must execute APPROVE(PAYMENT)");
        ctx.approvableScopes = SCOPE_PAYMENT;
        assertApprovesFrame(paymaster, ctx, "later paymaster must approve the transaction cost");
    }

    function test_accountSuite_paysForAnotherSender() public {
        address otherSender = accountSuiteOtherSender();
        deployAccount("OwnerAccount", otherSender);
        vm.store(otherSender, bytes32(0), bytes32(uint256(uint160(otherSender))));
        vm.deal(otherSender, 0);
        vm.deal(accountUnderTest(), SUITE_MAX_COST);
        (, uint256[] memory accountIndices) = conformanceSignatures();
        IFrameVm.FrameTx memory ctx = paysOtherSenderContext(accountIndices);
        assertTrue(ctx.sender != accountUnderTest(), "payment beneficiary must be another sender");
        assertEq(ctx.frames[1].flags, SCOPE_PAYMENT, "payer frame must permit exactly PAYMENT");

        ctx.frameIndex = 0;
        ctx.frames[0].status = 0;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(otherSender, ctx, "other sender must execute APPROVE(EXECUTION)");
        ctx.approvableScopes = SCOPE_EXECUTION;
        assertApprovesFrame(otherSender, ctx, "other sender must first approve its own execution");

        ctx.frameIndex = 1;
        ctx.frames[0].status = 1;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(accountUnderTest(), ctx, "payer role must execute APPROVE(PAYMENT)");
        ctx.approvableScopes = SCOPE_PAYMENT;
        assertApprovesFrame(
            accountUnderTest(), ctx, "account must be able to pay for another sender"
        );
    }

    function test_accountSuite_signatureRoutingIgnoresUnselectedValidAuthorization() public {
        IFrameVm.FrameTx memory ctx = selfPayContext(strangerIndices());
        assertRefusesFrame(
            accountUnderTest(),
            ctx,
            "selecting strangers must fail even when valid account signatures exist elsewhere"
        );
    }

    function test_accountSuite_emptySignatureSelectionIsRefused() public {
        uint256[] memory noIndices = new uint256[](0);
        assertRefusesFrame(
            accountUnderTest(),
            selfPayContext(noIndices),
            "an empty signature selection must not authorize the account"
        );
    }

    function test_accountSuite_outOfRangeSignatureSelectionIsRefused() public {
        (IFrameVm.FrameTxSignature[] memory signatures,) = conformanceSignatures();
        assertRefusesFrame(
            accountUnderTest(),
            selfPayContext(selected(signatures.length)),
            "an out-of-range signature index must not authorize the account"
        );
    }

    function test_accountSuite_acceptsOrdinaryEthFunding() public {
        address account = accountUnderTest();
        uint256 beforeBalance = account.balance;
        vm.deal(address(this), 1 ether);
        (bool ok,) = payable(account).call{value: 1 wei}("");
        assertTrue(ok, "account payment role requires an ordinary ETH funding path");
        assertEq(account.balance, beforeBalance + 1 wei, "account must retain funded ETH");
    }
}
