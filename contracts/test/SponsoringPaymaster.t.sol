// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFrameVm} from "./FrameTest.sol";
import {PaymasterTestSuite} from "./PaymasterTestSuite.sol";

/// examples/06-paymaster, executed against the real opcodes.
///
/// The paymaster is a third party, so it approves PAYMENT only. It runs no
/// `ecrecover`: the protocol verified every entry in `tx.signatures` before any
/// frame ran, and all this contract decides is whether the key at `sigIndex` is
/// the one it sponsors for, over this transaction, under its cost cap.
///
/// Deployed through its constructor rather than etched: `sponsorSigner`,
/// `maxSponsoredCost` and `owner` are immutables, which `--bin-runtime` emits as
/// zeroed PUSH32 placeholders, so an etched paymaster would sponsor address(0) at a
/// cap of zero and no assertion here would mean anything.
contract SponsoringPaymasterTest is PaymasterTestSuite {
    address constant SENDER_ACCOUNT = address(0xACC0);
    address constant SPONSOR = address(0x5B05);
    address constant OTHER_KEY = address(0xBAD);

    uint256 constant MAX_SPONSORED_COST = 1 ether;

    /// Index of the sponsor's entry in `tx.signatures`; the sender's own is at 0.
    uint256 constant SPONSOR_SIG = 1;

    address paymaster;

    function setUp() public {
        paymaster =
            deployAccountWithArgs("SponsoringPaymaster", abi.encode(SPONSOR, MAX_SPONSORED_COST));
        // Keep the non-zero-cost fixture realistically funded. setFrameTx does
        // not itself test the balance precondition or measure an ETH debit.
        vm.deal(paymaster, 10 ether);

        (bool ok, bytes memory ret) =
            paymaster.staticcall(abi.encodeWithSignature("sponsorSigner()"));
        require(ok, "sponsorSigner() failed");
        assertEq(abi.decode(ret, (address)), SPONSOR, "immutable sponsorSigner not filled in");
        (ok, ret) = paymaster.staticcall(abi.encodeWithSignature("maxSponsoredCost()"));
        require(ok, "maxSponsoredCost() failed");
        assertEq(abi.decode(ret, (uint256)), MAX_SPONSORED_COST, "immutable cap not filled in");
    }

    // PaymasterTestSuite hooks. Future paymaster tests can implement the same
    // four hooks to inherit the complete account-policy sponsorship matrix.
    function _paymasterUnderTest() internal view override returns (address) {
        return paymaster;
    }

    function _paymasterTestSignature()
        internal
        pure
        override
        returns (IFrameVm.FrameTxSignature memory signature)
    {
        signature = secpSig(SPONSOR);
    }

    function _paymasterTestCall(uint256 signatureIndex)
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encodeWithSignature("sponsorTransaction(uint256)", signatureIndex);
    }

    function _paymasterTestMaxCost() internal pure override returns (uint256) {
        return 0.5 ether;
    }

    /// The canonical paymaster prefix: frame 0 is the sender's `only_verify`
    /// (flags 0x2), frame 1 the `pay` frame targeting this paymaster (flags 0x1).
    /// The context is positioned on frame 1, the one under test.
    function _payCtx(uint256 sigIndex, uint256 maxCost, uint64 scopes)
        internal
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](3);
        frames[0] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(SCOPE_EXECUTION),
            target: SENDER_ACCOUNT,
            gasLimit: 100_000,
            stateGasLimit: 0,
            value: 0,
            data: abi.encodeWithSignature("validate(uint256)", uint256(0)),
            // Documents the preceding successful execution approval. The synthetic
            // fixture does not persist sender_approved across separate calls.
            status: 1,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        frames[1] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(scopes),
            target: paymaster,
            gasLimit: 100_000,
            stateGasLimit: 0,
            value: 0,
            data: abi.encodeWithSignature("sponsorTransaction(uint256)", sigIndex),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        frames[2] = IFrameVm.FrameTxFrame({
            mode: MODE_SENDER,
            flags: 0,
            target: address(0x7043),
            gasLimit: 100_000,
            stateGasLimit: 0,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", OTHER_KEY, uint256(1)),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });

        IFrameVm.FrameTxSignature[] memory sigs = new IFrameVm.FrameTxSignature[](2);
        sigs[0] = secpSig(SENDER_ACCOUNT);
        sigs[1] = secpSig(SPONSOR);
        uint256[] memory nonceKeys = legacyNonceKeys();

        ctx = IFrameVm.FrameTx({
            sender: SENDER_ACCOUNT,
            nonce: 0,
            legacyNonce: 0,
            nonceKeys: nonceKeys,
            nonceKeysHash: LEGACY_NONCE_KEYS_HASH,
            stateGasLeft: 0,
            sigHash: bytes32(uint256(0xf00d)),
            maxCost: maxCost,
            maxPriorityFeePerGas: 0,
            maxFeePerGas: 0,
            maxFeePerBlobGas: 0,
            blobCount: 0,
            frameIndex: 1,
            frames: frames,
            signatures: sigs,
            recentRootReferences: new IFrameVm.FrameTxRecentRootReference[](0),
            trace: emptyTrace(),
            approvableScopes: scopes
        });
    }

    function _payCtx() internal view returns (IFrameVm.FrameTx memory) {
        return _payCtx(SPONSOR_SIG, 0.5 ether, SCOPE_PAYMENT);
    }

    // ------------------------------------------------------------------ positive

    function test_sponsorSignatureApprovesPayment() public {
        assertApprovesFrame(paymaster, _payCtx(), "the sponsor's entry must approve payment");
    }

    /// The cap is inclusive, and the boundary is where an off-by-one would hide.
    function test_maxCostExactlyAtCapApproves() public {
        assertApprovesFrame(
            paymaster,
            _payCtx(SPONSOR_SIG, MAX_SPONSORED_COST, SCOPE_PAYMENT),
            "max cost equal to the cap must still be sponsored"
        );
    }

    // ------------------------------------------------------------------ negative

    /// Same transaction, but `sigIndex` points at the sender's entry instead of the
    /// sponsor's. The key is protocol-verified; it is simply not the one we sponsor for.
    function test_wrongSignerRefused() public {
        assertRefusesFrame(
            paymaster, _payCtx(0, 0.5 ether, SCOPE_PAYMENT), "only the sponsor key may authorise"
        );
    }

    function test_signerThatIsNotTheSponsorRefused() public {
        IFrameVm.FrameTx memory ctx = _payCtx();
        ctx.signatures[SPONSOR_SIG].signer = OTHER_KEY;
        assertRefusesFrame(paymaster, ctx, "a stranger's entry must not buy sponsorship");
    }

    /// A non-zero `msg` is a digest the sponsor signed over something else, which a
    /// relayer could staple onto an unrelated transaction for free gas.
    function test_explicitDigestRefused() public {
        IFrameVm.FrameTx memory ctx = _payCtx();
        ctx.signatures[SPONSOR_SIG].msgHash = bytes32(uint256(0xbeef));
        assertRefusesFrame(paymaster, ctx, "an explicit digest must not authorise sponsorship");
    }

    /// SIGPARAM(0x00) on an ARBITRARY entry is an exceptional halt, so the contract
    /// reads the scheme first and produces a clean BadScheme revert instead.
    function test_arbitrarySchemeRefused() public {
        IFrameVm.FrameTx memory ctx = _payCtx();
        ctx.signatures[SPONSOR_SIG].scheme = 0;
        assertRefusesFrame(paymaster, ctx, "an ARBITRARY entry has no protocol signer");
    }

    function test_p256SchemeRefused() public {
        IFrameVm.FrameTx memory ctx = _payCtx();
        ctx.signatures[SPONSOR_SIG].scheme = 2;
        assertRefusesFrame(paymaster, ctx, "this paymaster accepts SECP256K1 only");
    }

    function test_mldsaSchemeRefused() public {
        IFrameVm.FrameTx memory ctx = _payCtx();
        ctx.signatures[SPONSOR_SIG] = mldsaSig(SPONSOR);
        assertRefusesFrame(paymaster, ctx, "this paymaster accepts SECP256K1 only");
    }

    function test_maxCostAboveCapRefused() public {
        assertRefusesFrame(
            paymaster,
            _payCtx(SPONSOR_SIG, MAX_SPONSORED_COST + 1, SCOPE_PAYMENT),
            "a max cost above the cap must not be sponsored"
        );
    }

    /// An out-of-range index halts on the first SIGPARAM, before the scheme check.
    function test_outOfRangeSigIndexRefused() public {
        assertRefusesFrame(
            paymaster, _payCtx(7, 0.5 ether, SCOPE_PAYMENT), "sigIndex past the end of the list"
        );
    }

    /// The paymaster is not `tx.sender`, so a `pay` frame may never carry execution.
    /// Same sponsor entry as the positive case; only the frame's flags change.
    function test_scopeOutsideFrameFlagsRefused() public {
        assertRefusesFrame(
            paymaster,
            _payCtx(SPONSOR_SIG, 0.5 ether, SCOPE_EXECUTION),
            "APPROVE(PAYMENT) must revert on an execution-only frame"
        );
    }

    function test_scopeNoneRefused() public {
        assertRefusesFrame(
            paymaster, _payCtx(SPONSOR_SIG, 0.5 ether, SCOPE_NONE), "APPROVE_NONE must revert"
        );
    }
}
