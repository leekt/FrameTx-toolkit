// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";
import {IFrameAccount} from "../src/accounts/IFrameAccount.sol";

/// Reusable conformance tests for a paymaster.
///
/// A concrete paymaster test supplies its deployed target, the signature entries
/// that authorise sponsorship, and the calldata which selects those entries. Its
/// `setUp` must leave the paymaster able to approve `_paymasterTestMaxCost()`.
///
/// Each positive case drives both VERIFY frames from the same three-frame
/// transaction fixture:
///
///   account VERIFY (EXECUTION) -> paymaster VERIFY (PAYMENT) -> SENDER
///
/// The signature envelope is deliberately shared and shifted:
/// `[distractor, owner A, owner B, paymaster...]`. Single-owner policies receive
/// `[1]`, the 2-of-3 multisig receives `[1, 2]`, and the paymaster receives the
/// contiguous indices beginning at `3` when its policy uses signature entries.
/// This proves that each frame follows its explicit routing rather than assuming
/// its signatures start at zero.
///
/// These are opcode-level approval tests, not end-to-end transaction accounting
/// tests. `approvableScopes` pins the only scope that may succeed in each call,
/// but the Foundry frame fixture does not prove an ETH debit or balance transfer.
abstract contract PaymasterTestSuite is FrameTest {
    address private constant DEFAULT_PORTABLE_YUL_ACCOUNT = address(0xA110);
    address private constant DEFAULT_BUILTIN_YUL_ACCOUNT = address(0xA111);
    address private constant DEFAULT_SENDER_TARGET = address(0x7043);

    // Fresh runtimes for contracts/src/accounts/account.yul and
    // contracts/src/accounts/account-builtins.yul, respectively. Both expose
    // validate(uint256[]) and read their sole selected index from calldata.
    bytes private constant PORTABLE_YUL_RUNTIME =
        hex"36600557005b606436146010575f5ffd5b6325b904945f3560e01c146022575f5ffd5b602060043514602f575f5ffd5b600160243514603c575f5ffd5b6044355f81b4600282b415600ab0600681b3806056575f5ffd5b82845f54141615606557805f5faa5b5f5ffd";
    bytes private constant BUILTIN_YUL_RUNTIME =
        hex"3615606557606436036061576325b904945f3560e01c03605d5760206004350360595760016024350360555760443560025f82b491b4156006600ab0b39182156051575f541416604d575f80fd5b5f80aa5b5f80fd5b5f80fd5b5f80fd5b5f80fd5b5f80fd5b00";

    /// The deployed paymaster under test.
    function _paymasterUnderTest() internal view virtual returns (address);

    /// Override these if the paymaster under test reserves one of the default
    /// fixture addresses.
    function _paymasterSuitePortableYulAccount() internal view virtual returns (address) {
        return DEFAULT_PORTABLE_YUL_ACCOUNT;
    }

    function _paymasterSuiteBuiltinYulAccount() internal view virtual returns (address) {
        return DEFAULT_BUILTIN_YUL_ACCOUNT;
    }

    function _paymasterSuiteSenderTarget() internal view virtual returns (address) {
        return DEFAULT_SENDER_TARGET;
    }

    /// The protocol-verified entries that satisfy the paymaster's policy.
    function _paymasterTestSignatures()
        internal
        view
        virtual
        returns (IFrameVm.FrameTxSignature[] memory);

    /// Calldata for the paymaster VERIFY frame, selecting its envelope entries.
    function _paymasterTestCall(uint256[] memory signatureIndices)
        internal
        view
        virtual
        returns (bytes memory);

    /// A max-cost fixture accepted by the configured paymaster.
    function _paymasterTestMaxCost() internal view virtual returns (uint256);

    /// Optional setup for sender-specific allowlists or proofs. It runs after
    /// the account is deployed and before the shared transaction fixture is
    /// built. Signature hooks should otherwise remain stable during one case.
    function _preparePaymasterForAccount(address account) internal virtual {}

    function _differentFromPaymaster(uint160 candidate) private view returns (address result) {
        result = address(candidate);
        IFrameVm.FrameTxSignature[] memory paymasterSignatures = _paymasterTestSignatures();
        bool collided = true;
        while (collided) {
            collided = false;
            for (uint256 i = 0; i < paymasterSignatures.length; ++i) {
                if (result == paymasterSignatures[i].signer) {
                    result = address(uint160(result) + 1);
                    collided = true;
                    break;
                }
            }
        }
    }

    function _suiteOwnerA() private view returns (address) {
        return _differentFromPaymaster(0x1111);
    }

    function _suiteOwnerB() private view returns (address) {
        return _differentFromPaymaster(0x2222);
    }

    function _suiteDistractor() private view returns (address) {
        return _differentFromPaymaster(0xD157);
    }

    function _singleIndex(uint256 index) private pure returns (uint256[] memory indices) {
        indices = new uint256[](1);
        indices[0] = index;
    }

    function _multisigIndices() private pure returns (uint256[] memory indices) {
        indices = new uint256[](2);
        indices[0] = 1;
        indices[1] = 2;
    }

    function _paymasterIndices() private view returns (uint256[] memory indices) {
        uint256 count = _paymasterTestSignatures().length;
        indices = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            indices[i] = i + 3;
        }
    }

    function _sharedSignatures()
        private
        view
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        IFrameVm.FrameTxSignature[] memory paymasterSignatures = _paymasterTestSignatures();
        signatures = new IFrameVm.FrameTxSignature[](paymasterSignatures.length + 3);
        signatures[0] = secpSig(_suiteDistractor());
        signatures[1] = secpSig(_suiteOwnerA());
        signatures[2] = secpSig(_suiteOwnerB());
        for (uint256 i = 0; i < paymasterSignatures.length; ++i) {
            signatures[i + 3] = paymasterSignatures[i];
        }
    }

    function _sponsoredContext(address account, uint256[] memory accountSignatureIndices)
        private
        view
        returns (IFrameVm.FrameTx memory ctx)
    {
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](3);
        frames[0] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(SCOPE_EXECUTION),
            target: account,
            gasLimit: 300_000,
            stateGasLimit: 0,
            value: 0,
            data: abi.encodeWithSelector(IFrameAccount.validate.selector, accountSignatureIndices),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        frames[1] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: uint8(SCOPE_PAYMENT),
            target: _paymasterUnderTest(),
            gasLimit: 200_000,
            stateGasLimit: 0,
            value: 0,
            data: _paymasterTestCall(_paymasterIndices()),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });
        frames[2] = IFrameVm.FrameTxFrame({
            mode: MODE_SENDER,
            flags: 0,
            target: _paymasterSuiteSenderTarget(),
            gasLimit: 100_000,
            stateGasLimit: 0,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", address(0xBEEF), uint256(1)),
            status: 0,
            executionGasUsed: 0,
            stateGasUsed: 0
        });

        uint256[] memory nonceKeys = legacyNonceKeys();
        ctx = IFrameVm.FrameTx({
            sender: account,
            nonce: 0,
            legacyNonce: 0,
            nonceKeys: nonceKeys,
            nonceKeysHash: LEGACY_NONCE_KEYS_HASH,
            stateGasLeft: 0,
            sigHash: bytes32(uint256(0xf00d)),
            maxCost: _paymasterTestMaxCost(),
            maxPriorityFeePerGas: 0,
            maxFeePerGas: 0,
            maxFeePerBlobGas: 0,
            blobCount: 0,
            frameIndex: 0,
            frames: frames,
            signatures: _sharedSignatures(),
            recentRootReferences: new IFrameVm.FrameTxRecentRootReference[](0),
            trace: emptyTrace(),
            approvableScopes: SCOPE_EXECUTION
        });
    }

    function _assertAccountThenPaymasterApprove(
        IFrameVm.FrameTx memory ctx,
        string memory accountReason,
        string memory paymasterReason
    ) private {
        assertEq(ctx.frames[0].flags, SCOPE_EXECUTION, "account frame scope must be exact");
        assertEq(ctx.frames[1].flags, SCOPE_PAYMENT, "paymaster frame scope must be exact");

        // First deny all approvals while keeping the frame unchanged. A plain
        // RETURN would still succeed, so this refusal proves the positive call
        // below actually reaches APPROVE(EXECUTION).
        ctx.frameIndex = 0;
        ctx.frames[0].status = 0;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(ctx.sender, ctx, "account must require its execution approval scope");

        ctx.approvableScopes = SCOPE_EXECUTION;
        assertApprovesFrame(ctx.sender, ctx, accountReason);

        // setFrameTx is a per-call fixture. The preceding status is documentary:
        // this cheatcode does not persist sender_approved from the account call.
        // The NONE probe still proves that the paymaster's success reaches
        // APPROVE(PAYMENT), rather than an ordinary return.
        ctx.frameIndex = 1;
        ctx.frames[0].status = 1;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(
            _paymasterUnderTest(), ctx, "paymaster must require its payment approval scope"
        );

        ctx.approvableScopes = SCOPE_PAYMENT;
        assertApprovesFrame(_paymasterUnderTest(), ctx, paymasterReason);
    }

    function _ownerAccount() private returns (address) {
        return deployAccountWithArgs("OwnerAccount", abi.encode(_suiteOwnerA()));
    }

    function _multisigAccount() private returns (address) {
        address[] memory owners = new address[](3);
        owners[0] = _suiteOwnerA();
        owners[1] = _suiteOwnerB();
        owners[2] = address(0x3333);
        return deployAccountWithArgs("MultisigAccount", abi.encode(owners, uint256(2)));
    }

    function _sessionKeyAccount() private returns (address) {
        // The suite deliberately uses the owner path, which is unconditional;
        // session-key expiry and allowlist behavior belongs to the account suite.
        return deployAccountWithArgs("SessionKeyAccount", abi.encode(_suiteOwnerA()));
    }

    function _installYulAccount(address account, bytes memory runtime) private {
        vm.etch(account, runtime);
        vm.store(account, bytes32(0), bytes32(uint256(uint160(_suiteOwnerA()))));
    }

    function test_paymasterConformance_sponsorsOwnerAccount() public {
        address account = _ownerAccount();
        _preparePaymasterForAccount(account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(account, _singleIndex(1)),
            "owner account must approve execution from shifted signature index 1",
            "paymaster must sponsor the owner account from indices beginning at 3"
        );
    }

    function test_paymasterConformance_sponsorsMultisigAccount() public {
        address account = _multisigAccount();
        _preparePaymasterForAccount(account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(account, _multisigIndices()),
            "multisig must approve execution from shifted signature indices 1 and 2",
            "paymaster must sponsor the multisig account from indices beginning at 3"
        );
    }

    function test_paymasterConformance_sponsorsSessionKeyAccountViaOwner() public {
        address account = _sessionKeyAccount();
        _preparePaymasterForAccount(account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(account, _singleIndex(1)),
            "session-key account owner must approve execution from shifted signature index 1",
            "paymaster must sponsor the session-key account from indices beginning at 3"
        );
    }

    function test_paymasterConformance_sponsorsPortableYulAccount() public {
        address account = _paymasterSuitePortableYulAccount();
        _installYulAccount(account, PORTABLE_YUL_RUNTIME);
        _preparePaymasterForAccount(account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(account, _singleIndex(1)),
            "portable Yul account must approve execution from shifted signature index 1",
            "paymaster must sponsor the portable Yul account from indices beginning at 3"
        );
    }

    function test_paymasterConformance_sponsorsBuiltinYulAccount() public {
        address account = _paymasterSuiteBuiltinYulAccount();
        _installYulAccount(account, BUILTIN_YUL_RUNTIME);
        _preparePaymasterForAccount(account);
        _assertAccountThenPaymasterApprove(
            _sponsoredContext(account, _singleIndex(1)),
            "builtin Yul account must approve execution from shifted signature index 1",
            "paymaster must sponsor the builtin Yul account from indices beginning at 3"
        );
    }

    function test_paymasterConformance_wrongSelectedPaymasterIndexIsRefused() public {
        address account = _ownerAccount();
        _preparePaymasterForAccount(account);
        uint256 paymasterSignatureCount = _paymasterTestSignatures().length;
        if (paymasterSignatureCount == 0) return;

        IFrameVm.FrameTx memory ctx = _sponsoredContext(account, _singleIndex(1));

        // Prove the account route remains valid, then misroute the paymaster to
        // that account entry instead of its own entries beginning at index 3.
        ctx.frameIndex = 0;
        ctx.approvableScopes = SCOPE_NONE;
        assertRefusesFrame(account, ctx, "account must require its execution approval scope");

        ctx.approvableScopes = SCOPE_EXECUTION;
        assertApprovesFrame(account, ctx, "account signature index 1 must remain valid");

        uint256[] memory wrongIndices = new uint256[](paymasterSignatureCount);
        for (uint256 i = 0; i < wrongIndices.length; ++i) {
            wrongIndices[i] = 1;
        }
        ctx.frames[1].data = _paymasterTestCall(wrongIndices);
        ctx.frames[0].status = 1;
        ctx.frameIndex = 1;
        ctx.approvableScopes = SCOPE_PAYMENT;
        assertRefusesFrame(
            _paymasterUnderTest(),
            ctx,
            "paymaster must not treat the account-selected signature as its authorisation"
        );
    }
}
