// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFrameVm} from "./FrameTest.sol";
import {PaymasterTestSuite} from "./PaymasterTestSuite.sol";
import {MLDSAPaymaster} from "../src/accounts/MLDSAPaymaster.sol";
import {MLDSA44} from "../src/crypto/MLDSA44.sol";

contract RejectMLDSAWithdrawal {
    receive() external payable {
        revert();
    }
}

/// Native ML-DSA-44 paymaster policy tests. Inheriting PaymasterTestSuite
/// proves sponsorship across every account implementation in its matrix.
contract MLDSAPaymasterTest is PaymasterTestSuite {
    uint8 private constant SCHEME_SECP256K1 = 1;
    uint8 private constant SCHEME_P256 = 2;
    uint8 private constant SCHEME_ML_DSA_44 = 3;
    uint256 private constant MAX_SPONSORED_COST = 1 ether;
    address private constant SENDER_ACCOUNT = address(0xA44);

    address internal paymaster;
    address internal sponsorSigner;
    bytes internal sponsorPublicKey;

    function setUp() public {
        sponsorPublicKey = _publicKey(0xc3);
        sponsorSigner = _signer(sponsorPublicKey);
        paymaster = deployAccountWithArgs(
            "MLDSAPaymaster", abi.encode(sponsorPublicKey, MAX_SPONSORED_COST)
        );
        vm.deal(paymaster, 10 ether);

        MLDSAPaymaster subject = MLDSAPaymaster(payable(paymaster));
        assertEq(subject.owner(), address(this), "immutable owner");
        assertEq(subject.sponsorSigner(), sponsorSigner, "constructor key identity");
        assertEq(subject.maxSponsoredCost(), MAX_SPONSORED_COST, "constructor cost cap");
    }

    function _paymasterUnderTest() internal view override returns (address) {
        return paymaster;
    }

    function _paymasterTestSignature()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature memory signature)
    {
        signature = _signature(SCHEME_ML_DSA_44, sponsorSigner, bytes32(0));
    }

    function _paymasterTestCall(uint256 signatureIndex)
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encodeWithSelector(MLDSAPaymaster.sponsorTransaction.selector, signatureIndex);
    }

    function _paymasterTestMaxCost() internal pure override returns (uint256) {
        return 0.5 ether;
    }

    function _publicKey(uint256 seed) internal pure returns (bytes memory key) {
        key = new bytes(1_312);
        for (uint256 i; i < key.length; ++i) {
            key[i] = bytes1(uint8((seed + i) & 0xff));
        }
    }

    function _signer(bytes memory key) internal pure returns (address) {
        require(key.length == 1_312, "test key length");
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0x03), key)))));
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

    function _payContext(
        IFrameVm.FrameTxSignature[] memory signatures,
        uint256 signatureIndex,
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
                MLDSAPaymaster.sponsorTransaction.selector, signatureIndex
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

    function test_signerUsesSchemeDomainSeparatedPublicKeyDerivation() public view {
        assertEq(
            MLDSAPaymaster(payable(paymaster)).signerForKey(sponsorPublicKey),
            sponsorSigner,
            "signer must be low20(keccak256(0x03 || publicKey))"
        );
    }

    function test_secp256k1SponsorEntryIsRefused() public {
        assertRefusesFrame(
            paymaster,
            _payContext(
                _singleSignature(SCHEME_SECP256K1, sponsorSigner, bytes32(0)),
                0,
                0.5 ether,
                SCOPE_PAYMENT
            ),
            "the paymaster must require native ML-DSA-44"
        );
    }

    function test_p256SponsorEntryIsRefused() public {
        assertRefusesFrame(
            paymaster,
            _payContext(
                _singleSignature(SCHEME_P256, sponsorSigner, bytes32(0)),
                0,
                0.5 ether,
                SCOPE_PAYMENT
            ),
            "P256 must not masquerade as ML-DSA-44"
        );
    }

    function test_differentMLDSASponsorIsRefused() public {
        address otherSigner = _signer(_publicKey(0x42));
        assertRefusesFrame(
            paymaster,
            _payContext(
                _singleSignature(SCHEME_ML_DSA_44, otherSigner, bytes32(0)),
                0,
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
                _singleSignature(SCHEME_ML_DSA_44, sponsorSigner, keccak256("unrelated")),
                0,
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
                _singleSignature(SCHEME_ML_DSA_44, sponsorSigner, bytes32(0)),
                0,
                MAX_SPONSORED_COST + 1,
                SCOPE_PAYMENT
            ),
            "the signed transaction must remain within the sponsor cap"
        );
    }

    function test_scopeMustBeExactlyPayment() public {
        IFrameVm.FrameTxSignature[] memory signatures =
            _singleSignature(SCHEME_ML_DSA_44, sponsorSigner, bytes32(0));
        assertRefusesFrame(
            paymaster,
            _payContext(signatures, 0, 0.5 ether, SCOPE_BOTH),
            "a paymaster frame must not advertise execution approval"
        );
        assertRefusesFrame(
            paymaster,
            _payContext(signatures, 0, 0.5 ether, SCOPE_EXECUTION),
            "a paymaster frame must include payment approval"
        );
        assertRefusesFrame(
            paymaster,
            _payContext(signatures, 0, 0.5 ether, SCOPE_NONE),
            "a paymaster frame must not have an empty scope"
        );
    }

    function test_selectsTrustedEntryAfterUnrelatedEntry() public {
        IFrameVm.FrameTxSignature[] memory signatures = new IFrameVm.FrameTxSignature[](2);
        signatures[0] = _signature(SCHEME_P256, sponsorSigner, bytes32(0));
        signatures[1] = _signature(SCHEME_ML_DSA_44, sponsorSigner, bytes32(0));

        assertApprovesFrame(
            paymaster,
            _payContext(signatures, 1, 0.5 ether, SCOPE_PAYMENT),
            "the selected trusted ML-DSA-44 entry may follow an unrelated entry"
        );
        assertRefusesFrame(
            paymaster,
            _payContext(signatures, 0, 0.5 ether, SCOPE_PAYMENT),
            "an unselected trusted entry must not authorise"
        );
    }

    function test_outOfRangeSignatureSelectionIsRefused() public {
        assertRefusesFrame(
            paymaster,
            _payContext(
                _singleSignature(SCHEME_ML_DSA_44, sponsorSigner, bytes32(0)),
                1,
                0.5 ether,
                SCOPE_PAYMENT
            ),
            "an out-of-range signature index must not authorize sponsorship"
        );
    }

    function test_legacyArraySignatureSelectionAbiIsRefused() public {
        IFrameVm.FrameTx memory ctx = _payContext(
            _singleSignature(SCHEME_ML_DSA_44, sponsorSigner, bytes32(0)),
            0,
            0.5 ether,
            SCOPE_PAYMENT
        );
        uint256[] memory legacyIndices = new uint256[](1);
        legacyIndices[0] = 0;
        ctx.frames[1].data = abi.encodeWithSignature("sponsorTransaction(uint256[])", legacyIndices);
        assertRefusesFrame(paymaster, ctx, "the removed dynamic-array ABI must not authorize");
    }

    function test_receiveAndOwnerWithdrawal() public {
        vm.deal(address(this), 1 ether);
        uint256 beforeFunding = paymaster.balance;
        (bool ok,) = payable(paymaster).call{value: 1 wei}("");
        assertTrue(ok, "paymaster must accept sponsorship funding");
        assertEq(paymaster.balance, beforeFunding + 1 wei, "funding balance");

        address payable recipient = payable(address(0xBEEF));
        uint256 beforeRecipient = recipient.balance;
        MLDSAPaymaster(payable(paymaster)).withdraw(recipient, 0.25 ether);
        assertEq(recipient.balance, beforeRecipient + 0.25 ether, "owner withdrawal");
    }

    function test_nonOwnerWithdrawalIsRefused() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MLDSAPaymaster.NotOwner.selector);
        MLDSAPaymaster(payable(paymaster)).withdraw(payable(address(0xBEEF)), 1 wei);
    }

    function test_failedWithdrawalIsReported() public {
        RejectMLDSAWithdrawal recipient = new RejectMLDSAWithdrawal();
        vm.expectRevert(MLDSAPaymaster.WithdrawFailed.selector);
        MLDSAPaymaster(payable(paymaster)).withdraw(payable(address(recipient)), 1 wei);
    }

    function test_constructorRequiresExactPublicKeyLength() public {
        bytes memory emptyKey = new bytes(0);
        vm.expectRevert(
            abi.encodeWithSelector(MLDSA44.InvalidPublicKeyLength.selector, emptyKey.length)
        );
        new MLDSAPaymaster(emptyKey, MAX_SPONSORED_COST);

        bytes memory shortKey = new bytes(1_311);
        vm.expectRevert(
            abi.encodeWithSelector(MLDSA44.InvalidPublicKeyLength.selector, shortKey.length)
        );
        new MLDSAPaymaster(shortKey, MAX_SPONSORED_COST);

        bytes memory longKey = new bytes(1_313);
        vm.expectRevert(
            abi.encodeWithSelector(MLDSA44.InvalidPublicKeyLength.selector, longKey.length)
        );
        new MLDSAPaymaster(longKey, MAX_SPONSORED_COST);
    }
}
