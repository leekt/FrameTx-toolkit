// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFrameVm} from "./FrameTest.sol";
import {PaymasterTestSuite} from "./PaymasterTestSuite.sol";
import {P256Paymaster} from "../src/accounts/P256Paymaster.sol";

/// P256 paymaster policy tests. Inheriting PaymasterTestSuite proves that this
/// paymaster sponsors every account implementation in the toolkit.
contract P256PaymasterTest is PaymasterTestSuite {
    uint8 private constant SCHEME_SECP256K1 = 1;
    uint8 private constant SCHEME_P256 = 2;
    uint256 private constant P256_KEY =
        0x4567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef123;
    uint256 private constant OTHER_P256_KEY =
        0x567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234;
    uint256 private constant MAX_SPONSORED_COST = 1 ether;
    address private constant SENDER_ACCOUNT = address(0xACC0);

    address internal paymaster;
    address internal sponsorSigner;

    function setUp() public {
        (uint256 qx, uint256 qy) = vm.publicKeyP256(P256_KEY);
        sponsorSigner = _signer(bytes32(qx), bytes32(qy));
        paymaster = deployAccountWithArgs(
            "P256Paymaster", abi.encode(bytes32(qx), bytes32(qy), MAX_SPONSORED_COST)
        );
        vm.deal(paymaster, 10 ether);

        assertEq(
            P256Paymaster(payable(paymaster)).sponsorSigner(),
            sponsorSigner,
            "constructor key identity"
        );
        assertEq(
            P256Paymaster(payable(paymaster)).maxSponsoredCost(),
            MAX_SPONSORED_COST,
            "constructor cost cap"
        );
    }

    function _paymasterUnderTest() internal view override returns (address) {
        return paymaster;
    }

    function _paymasterTestSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _signature(SCHEME_P256, sponsorSigner, bytes32(0));
    }

    function _paymasterTestCall(uint256[] memory signatureIndices)
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encodeWithSelector(P256Paymaster.sponsorTransaction.selector, signatureIndices);
    }

    function _paymasterTestMaxCost() internal pure override returns (uint256) {
        return 0.5 ether;
    }

    function _signer(bytes32 x, bytes32 y) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    function _signature(uint8 scheme, address claimedSigner, bytes32 msgHash)
        internal
        pure
        returns (IFrameVm.FrameTxSignature memory)
    {
        return IFrameVm.FrameTxSignature({
            scheme: scheme, signer: claimedSigner, msgHash: msgHash, signature: ""
        });
    }

    function _indices(uint256 a) internal pure returns (uint256[] memory result) {
        result = new uint256[](1);
        result[0] = a;
    }

    function _indices(uint256 a, uint256 b) internal pure returns (uint256[] memory result) {
        result = new uint256[](2);
        result[0] = a;
        result[1] = b;
    }

    function _payContext(
        IFrameVm.FrameTxSignature[] memory signatures,
        uint256[] memory signatureIndices,
        uint256 maxCost,
        uint64 scope
    ) internal view returns (IFrameVm.FrameTx memory ctx) {
        ctx = verifyContext(SENDER_ACCOUNT, scope, bytes32(uint256(0xf00d)));
        ctx.sender = SENDER_ACCOUNT;
        ctx.frameIndex = 1;
        ctx.frames = new IFrameVm.FrameTxFrame[](2);
        ctx.frames[0] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(SCOPE_EXECUTION),
            target: SENDER_ACCOUNT,
            gasLimit: 100_000,
            stateGasLimit: 0,
            value: 0,
            data: "",
            // Documents the preceding successful execution approval; the
            // synthetic fixture does not persist it between calls.
            status: 1,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        ctx.frames[1] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(scope),
            target: paymaster,
            gasLimit: 200_000,
            stateGasLimit: 0,
            value: 0,
            data: abi.encodeWithSelector(
                P256Paymaster.sponsorTransaction.selector, signatureIndices
            ),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        ctx.signatures = signatures;
        ctx.maxCost = maxCost;
        ctx.approvableScopes = scope;
    }

    function _singleSignature(uint8 scheme, address claimedSigner, bytes32 msgHash)
        internal
        pure
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = _signature(scheme, claimedSigner, msgHash);
    }

    function test_secp256k1SponsorEntryIsRefused() public {
        assertRefusesFrame(
            paymaster,
            _payContext(
                _singleSignature(SCHEME_SECP256K1, sponsorSigner, bytes32(0)),
                _indices(0),
                0.5 ether,
                SCOPE_PAYMENT
            ),
            "the paymaster must require the P256 protocol scheme"
        );
    }

    function test_differentP256SponsorIsRefused() public {
        (uint256 otherX, uint256 otherY) = vm.publicKeyP256(OTHER_P256_KEY);
        address otherSigner = _signer(bytes32(otherX), bytes32(otherY));
        assertRefusesFrame(
            paymaster,
            _payContext(
                _singleSignature(SCHEME_P256, otherSigner, bytes32(0)),
                _indices(0),
                0.5 ether,
                SCOPE_PAYMENT
            ),
            "only the configured sponsor key may authorise"
        );
    }

    function test_explicitDigestSponsorEntryIsRefused() public {
        assertRefusesFrame(
            paymaster,
            _payContext(
                _singleSignature(SCHEME_P256, sponsorSigner, keccak256("unrelated")),
                _indices(0),
                0.5 ether,
                SCOPE_PAYMENT
            ),
            "the sponsor must sign the complete frame transaction"
        );
    }

    function test_costAboveCapIsRefused() public {
        assertRefusesFrame(
            paymaster,
            _payContext(
                _singleSignature(SCHEME_P256, sponsorSigner, bytes32(0)),
                _indices(0),
                MAX_SPONSORED_COST + 1,
                SCOPE_PAYMENT
            ),
            "the signed transaction must remain within the sponsor cap"
        );
    }

    function test_scopeMustBeExactlyPayment() public {
        IFrameVm.FrameTxSignature[] memory signatures =
            _singleSignature(SCHEME_P256, sponsorSigner, bytes32(0));
        assertRefusesFrame(
            paymaster,
            _payContext(signatures, _indices(0), 0.5 ether, SCOPE_BOTH),
            "a paymaster frame must not advertise execution approval"
        );
        assertRefusesFrame(
            paymaster,
            _payContext(signatures, _indices(0), 0.5 ether, SCOPE_EXECUTION),
            "a paymaster frame must include payment approval"
        );
        assertRefusesFrame(
            paymaster,
            _payContext(signatures, _indices(0), 0.5 ether, SCOPE_NONE),
            "a paymaster frame must not have an empty scope"
        );
    }

    function test_scansOnlySelectedEntriesAndAcceptsASelectedTrustedEntry() public {
        IFrameVm.FrameTxSignature[] memory signatures = new IFrameVm.FrameTxSignature[](2);
        signatures[0] = _signature(SCHEME_SECP256K1, sponsorSigner, bytes32(0));
        signatures[1] = _signature(SCHEME_P256, sponsorSigner, bytes32(0));

        assertApprovesFrame(
            paymaster,
            _payContext(signatures, _indices(0, 1), 0.5 ether, SCOPE_PAYMENT),
            "the selected trusted P256 entry may follow an unrelated selected entry"
        );
        assertRefusesFrame(
            paymaster,
            _payContext(signatures, _indices(0), 0.5 ether, SCOPE_PAYMENT),
            "an unselected trusted entry must not authorise"
        );
    }

    function test_emptySelectionIsRefused() public {
        assertRefusesFrame(
            paymaster,
            _payContext(
                _singleSignature(SCHEME_P256, sponsorSigner, bytes32(0)),
                new uint256[](0),
                0.5 ether,
                SCOPE_PAYMENT
            ),
            "the paymaster needs an explicitly selected sponsor signature"
        );
    }

    function test_receiveAndOwnerWithdrawal() public {
        vm.deal(address(this), 1 ether);
        uint256 beforeFunding = paymaster.balance;
        (bool ok,) = payable(paymaster).call{value: 1 wei}("");
        assertTrue(ok, "paymaster must accept sponsorship funding");
        assertEq(paymaster.balance, beforeFunding + 1 wei, "funding balance");

        address payable recipient = payable(address(0xBEEF));
        uint256 beforeRecipient = recipient.balance;
        P256Paymaster(payable(paymaster)).withdraw(recipient, 0.25 ether);
        assertEq(recipient.balance, beforeRecipient + 0.25 ether, "owner withdrawal");
    }

    function test_nonOwnerWithdrawalIsRefused() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(P256Paymaster.NotOwner.selector);
        P256Paymaster(payable(paymaster)).withdraw(payable(address(0xBEEF)), 1 wei);
    }

    function test_allZeroSponsorKeyIsRefused() public {
        vm.expectRevert(P256Paymaster.InvalidPublicKey.selector);
        new P256Paymaster(bytes32(0), bytes32(0), MAX_SPONSORED_COST);
    }
}
