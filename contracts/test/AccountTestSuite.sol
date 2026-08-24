// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";

/// Reusable conformance tests for an EIP-8141 account implementation.
///
/// A concrete account test supplies only its deployed address and the canonical
/// signatures needed to satisfy its policy. The suite then proves that the account
/// can occupy each account-side approval role in the standard frame prefixes:
/// self relay (BOTH), sponsored relay (EXECUTION), and paying for another
/// sender as a sponsor only (PAYMENT).
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

    /// Encode the standard account ABI explicitly. Every non-multisig account
    /// receives exactly one envelope index. Multisig overrides this hook and
    /// expands the first contiguous authorization index into its threshold set.
    function validationCalldata(uint256 signatureIndex) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("validate(uint256)", signatureIndex);
    }

    function accountValidationCalldata(uint256 signatureIndex)
        internal
        view
        virtual
        returns (bytes memory)
    {
        require(
            accountAuthorizationSignatures().length == 1,
            "single-signature account must expose one authorization entry"
        );
        return validationCalldata(signatureIndex);
    }

    /// A threshold-sized stranger block precedes the account's selected entries.
    /// Thus every positive case reads valid account signatures at shifted,
    /// non-zero indices rather than accidentally depending on signature zero.
    function conformanceSignatures()
        internal
        view
        returns (IFrameVm.FrameTxSignature[] memory signatures, uint256 firstAuthorizationIndex)
    {
        IFrameVm.FrameTxSignature[] memory authorization = accountAuthorizationSignatures();
        IFrameVm.FrameTxSignature[] memory unauthorized = accountUnauthorizedSignatures();
        uint256 n = authorization.length;
        require(n != 0, "suite requires an authorization signature");
        require(unauthorized.length == n, "suite requires matching unauthorized signatures");

        signatures = new IFrameVm.FrameTxSignature[](n * 2);
        firstAuthorizationIndex = n;
        for (uint256 i = 0; i < n; ++i) {
            signatures[i] = unauthorized[i];
            signatures[firstAuthorizationIndex + i] = authorization[i];
        }
    }

    function conformanceValidationCalldata() internal view returns (bytes memory) {
        (, uint256 firstAuthorizationIndex) = conformanceSignatures();
        return accountValidationCalldata(firstAuthorizationIndex);
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

    function selfPayContext(bytes memory accountCallData)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        address account = accountUnderTest();
        ctx = verifyContext(account, SCOPE_BOTH, accountSuiteSigHash());
        ctx.frames = new IFrameVm.FrameTxFrame[](2);
        ctx.frames[0] = verifyFrame(account, SCOPE_BOTH, accountCallData, 0);
        ctx.frames[1] = senderFrame();
        (ctx.signatures,) = conformanceSignatures();
        ctx.maxCost = SUITE_MAX_COST;
        ctx.approvableScopes = SCOPE_BOTH;
    }

    function sponsoredContext(bytes memory accountCallData, address paymaster)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        address account = accountUnderTest();
        ctx = verifyContext(account, SCOPE_EXECUTION, accountSuiteSigHash());
        ctx.frames = new IFrameVm.FrameTxFrame[](3);
        ctx.frames[0] = verifyFrame(account, SCOPE_EXECUTION, accountCallData, 0);
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

    function sponsorOnlyContext(bytes memory accountCallData)
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
        ctx.frames[0] = verifyFrame(otherSender, SCOPE_EXECUTION, validationCalldata(0), 1);
        ctx.frames[1] = verifyFrame(account, SCOPE_PAYMENT, accountCallData, 0);
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
        bytes memory accountCallData = conformanceValidationCalldata();
        IFrameVm.FrameTx memory ctx = selfPayContext(accountCallData);
        assertEq(ctx.frames[0].flags, SCOPE_BOTH, "self frame must permit exactly BOTH");

        ctx.approvableScopes = SCOPE_PAYMENT;
        assertRefusesFrame(
            accountUnderTest(), ctx, "self relay must request BOTH, not PAYMENT only"
        );
        ctx = selfPayContext(accountCallData);
        ctx.approvableScopes = SCOPE_EXECUTION;
        assertRefusesFrame(
            accountUnderTest(), ctx, "self relay must request BOTH, not EXECUTION only"
        );
        ctx = selfPayContext(accountCallData);
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(accountUnderTest(), ctx, "self relay must execute APPROVE(BOTH)");

        ctx = selfPayContext(accountCallData);
        assertEq(ctx.approvableScopes, SCOPE_BOTH, "host scope must be exactly BOTH");
        assertApprovesFrame(accountUnderTest(), ctx, "account must verify and pay for itself");
    }

    function test_accountSuite_verifiesWhileLaterPaymasterPays() public {
        address paymaster = deployAccountWithArgs(
            "SponsoringPaymaster", abi.encode(accountSuitePaymasterSigner(), SUITE_MAX_COST)
        );
        vm.deal(accountUnderTest(), 0);
        vm.deal(paymaster, SUITE_MAX_COST);
        bytes memory accountCallData = conformanceValidationCalldata();
        IFrameVm.FrameTx memory ctx = sponsoredContext(accountCallData, paymaster);
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
        ctx = sponsoredContext(accountCallData, paymaster);
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

    function test_accountSuite_sponsorsAnotherSenderPaymentOnly() public {
        address otherSender = accountSuiteOtherSender();
        deployAccount("OwnerAccount", otherSender);
        vm.store(otherSender, bytes32(0), bytes32(uint256(uint160(otherSender))));
        vm.deal(otherSender, 0);
        vm.deal(accountUnderTest(), SUITE_MAX_COST);
        bytes memory accountCallData = conformanceValidationCalldata();
        IFrameVm.FrameTx memory ctx = sponsorOnlyContext(accountCallData);
        assertTrue(ctx.sender != accountUnderTest(), "sponsor must not be the transaction sender");
        assertEq(ctx.frames[1].flags, SCOPE_PAYMENT, "sponsor frame must permit only PAYMENT");

        ctx.frameIndex = 0;
        ctx.frames[0].status = 0;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(otherSender, ctx, "other sender must execute APPROVE(EXECUTION)");
        ctx.approvableScopes = SCOPE_EXECUTION;
        assertApprovesFrame(otherSender, ctx, "other sender must first approve its own execution");

        ctx.frameIndex = 1;
        ctx.frames[0].status = 1;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(accountUnderTest(), ctx, "sponsor role must execute APPROVE(PAYMENT)");
        ctx.approvableScopes = SCOPE_PAYMENT;
        assertApprovesFrame(
            accountUnderTest(), ctx, "account must sponsor payment without approving execution"
        );
    }

    function test_accountSuite_signatureRoutingIgnoresUnselectedValidAuthorization() public {
        IFrameVm.FrameTx memory ctx = selfPayContext(accountValidationCalldata(0));
        assertRefusesFrame(
            accountUnderTest(),
            ctx,
            "selecting strangers must fail even when valid account signatures exist elsewhere"
        );
    }

    function test_accountSuite_outOfRangeSignatureSelectionIsRefused() public {
        (IFrameVm.FrameTxSignature[] memory signatures,) = conformanceSignatures();
        assertRefusesFrame(
            accountUnderTest(),
            selfPayContext(accountValidationCalldata(signatures.length)),
            "an out-of-range signature index must not authorize the account"
        );
    }

    /// Every account policy must fail closed when its selected authorization is
    /// replaced by an ARBITRARY entry whose witness is malformed for the policy.
    /// Generic native-signature accounts fail when ARBITRARY has no resolved
    /// signer; contract-verified accounts such as WebAuthn reject the bad witness.
    function test_accountSuite_rejectsMalformedArbitrarySignature() public {
        (, uint256 firstAuthorizationIndex) = conformanceSignatures();
        IFrameVm.FrameTx memory ctx =
            selfPayContext(accountValidationCalldata(firstAuthorizationIndex));
        ctx.signatures[firstAuthorizationIndex] = arbitrarySig(hex"deadbeef");

        assertRefusesFrame(
            accountUnderTest(),
            ctx,
            "a malformed ARBITRARY signature must not authorize the account"
        );
    }

    /// `setFrameTx` models native entries after protocol verification, so raw
    /// native signature corruption cannot reach account bytecode here. These
    /// cases instead prove that wrong resolved native identities fail closed for
    /// every supported protocol scheme.
    function test_accountSuite_rejectsWrongSecp256k1Signature() public {
        _assertWrongNativeSignatureIsRefused(
            1, "a wrong secp256k1 signature must not authorize the account"
        );
    }

    function test_accountSuite_rejectsWrongP256Signature() public {
        _assertWrongNativeSignatureIsRefused(
            2, "a wrong P256 signature must not authorize the account"
        );
    }

    function _assertWrongNativeSignatureIsRefused(uint8 scheme, string memory reason) private {
        IFrameVm.FrameTxSignature[] memory authorization = accountAuthorizationSignatures();
        IFrameVm.FrameTxSignature[] memory noPriorStrangers = new IFrameVm.FrameTxSignature[](0);
        address stranger = _strangerNotInAuthorization(
            SUITE_STRANGER_BASE + uint160(0x100 + scheme), authorization, noPriorStrangers, 0
        );

        IFrameVm.FrameTxSignature memory wrongSignature;
        if (scheme == 1) {
            wrongSignature = secpSig(stranger);
        } else if (scheme == 2) {
            wrongSignature = p256Sig(stranger);
        } else {
            revert("unsupported native test scheme");
        }

        (, uint256 firstAuthorizationIndex) = conformanceSignatures();
        IFrameVm.FrameTx memory ctx =
            selfPayContext(accountValidationCalldata(firstAuthorizationIndex));
        ctx.signatures[firstAuthorizationIndex] = wrongSignature;
        assertRefusesFrame(accountUnderTest(), ctx, reason);
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
