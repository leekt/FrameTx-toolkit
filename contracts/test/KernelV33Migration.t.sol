// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccountTestSuite} from "./AccountTestSuite.sol";
import {IFrameVm} from "./FrameTest.sol";

import {KernelV33FrameAccount} from "../src/accounts/KernelV33FrameAccount.sol";

import {Kernel} from "kernel-v3.3/Kernel.sol";
import {KernelFactory} from "kernel-v3.3/factory/KernelFactory.sol";
import {IEntryPoint} from "kernel-v3.3/interfaces/IEntryPoint.sol";
import {IHook, IValidator} from "kernel-v3.3/interfaces/IERC7579Modules.sol";
import {PackedUserOperation} from "kernel-v3.3/interfaces/PackedUserOperation.sol";
import {
    ERC1967_IMPLEMENTATION_SLOT,
    VALIDATION_MANAGER_STORAGE_SLOT,
    MODULE_TYPE_EXECUTOR
} from "kernel-v3.3/types/Constants.sol";
import {ValidationData, ValidationId} from "kernel-v3.3/types/Types.sol";
import {ValidatorLib} from "kernel-v3.3/utils/ValidationTypeLib.sol";
import {ECDSAValidator} from "kernel-v3.3/validator/ECDSAValidator.sol";

/// A migration test against the actual ZeroDev Kernel v3.3 contracts pinned in
/// `vendor/kernel-v3.3`. The fixture starts with a deterministic KernelFactory
/// ERC-1967 proxy, initializes its real ECDSA root, mutates real Kernel state,
/// and then uses Kernel's own EntryPoint-authorized UUPS path to add EIP-8141.
contract KernelV33MigrationTest is AccountTestSuite {
    address internal constant ENTRY_POINT = address(0x4337);
    bytes32 internal constant FACTORY_SALT = keccak256("kernel-v3.3-existing-account");
    uint256 internal constant OWNER_KEY = 0xA11CE8141;
    uint256 internal constant MIGRATION_BALANCE = 1.5 ether;
    uint32 internal constant MIGRATED_NONCE_FLOOR = 5;
    address internal constant MIGRATED_EXECUTOR = address(0xE8141);

    Kernel internal legacyImplementation;
    KernelV33FrameAccount internal frameImplementation;
    KernelFactory internal kernelFactory;
    ECDSAValidator internal ecdsaValidator;

    address internal owner;
    address internal account;
    address internal predictedAccount;
    ValidationId internal rootBeforeMigration;
    bytes32 internal validationWordBeforeMigration;
    bytes32 internal proxyCodeHashBeforeMigration;
    uint256 internal balanceBeforeMigration;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        ecdsaValidator = new ECDSAValidator();
        legacyImplementation = new Kernel(IEntryPoint(ENTRY_POINT));
        frameImplementation =
            new KernelV33FrameAccount(address(legacyImplementation), ecdsaValidator);
        kernelFactory = new KernelFactory(address(legacyImplementation));

        bytes memory initialization = _initialization(ecdsaValidator, owner);
        predictedAccount = kernelFactory.getAddress(initialization, FACTORY_SALT);
        account = kernelFactory.createAccount(initialization, FACTORY_SALT);

        // Seed non-default Kernel state before migrating. This exercises the
        // namespaced validation and executor storage rather than mock sentinels.
        vm.prank(ENTRY_POINT);
        Kernel(payable(account))
            .installModule(
                MODULE_TYPE_EXECUTOR,
                MIGRATED_EXECUTOR,
                abi.encodePacked(address(0), abi.encode(bytes(""), bytes("")))
            );
        vm.prank(ENTRY_POINT);
        Kernel(payable(account)).invalidateNonce(MIGRATED_NONCE_FLOOR);
        vm.deal(account, MIGRATION_BALANCE);

        rootBeforeMigration = Kernel(payable(account)).rootValidator();
        validationWordBeforeMigration = vm.load(account, VALIDATION_MANAGER_STORAGE_SLOT);
        proxyCodeHashBeforeMigration = account.codehash;
        balanceBeforeMigration = account.balance;

        _upgrade(account, address(frameImplementation));
    }

    function accountUnderTest() internal view override returns (address) {
        return account;
    }

    function accountAuthorizationSignatures()
        internal
        view
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = secpSig(owner);
    }

    function test_kernelV33Migration_preservesAddressAndRealKernelState() public view {
        assertEq(account, predictedAccount, "factory prediction must be the existing address");
        assertEq(account.codehash, proxyCodeHashBeforeMigration, "proxy runtime must not change");
        assertEq(account.balance, balanceBeforeMigration, "account ETH must survive the upgrade");

        assertEq(
            vm.load(account, VALIDATION_MANAGER_STORAGE_SLOT),
            validationWordBeforeMigration,
            "Kernel validation namespace must be byte-for-byte preserved"
        );
        assertEq(
            bytes32(ValidationId.unwrap(Kernel(payable(account)).rootValidator())),
            bytes32(ValidationId.unwrap(rootBeforeMigration)),
            "root validation identifier must survive"
        );
        assertEq(
            Kernel(payable(account)).currentNonce(),
            MIGRATED_NONCE_FLOOR,
            "current validation nonce must survive"
        );
        assertEq(
            Kernel(payable(account)).validNonceFrom(),
            MIGRATED_NONCE_FLOOR,
            "nonce invalidation floor must survive"
        );
        assertEq(
            ecdsaValidator.ecdsaValidatorStorage(account),
            owner,
            "ECDSAValidator owner must survive"
        );
        assertTrue(
            Kernel(payable(account))
                .isModuleInstalled(MODULE_TYPE_EXECUTOR, MIGRATED_EXECUTOR, bytes("")),
            "installed executor mapping must survive and remain readable through the shim"
        );
        assertEq(
            _implementationOf(account),
            address(frameImplementation),
            "Kernel upgradeTo must install the Frame implementation"
        );
        assertEq(
            address(KernelV33FrameAccount(payable(account)).frameRootValidator()),
            address(ecdsaValidator),
            "implementation must pin the migrated root profile"
        );
        assertEq(
            address(Kernel(payable(account)).entrypoint()),
            ENTRY_POINT,
            "legacy fallback must retain the same EntryPoint"
        );
        assertEq(
            KernelV33FrameAccount(payable(account)).legacyImplementation(),
            address(legacyImplementation),
            "shim must delegate every legacy selector to the exact prior implementation"
        );
    }

    function test_kernelV33Migration_frameShimFitsEip170() public view {
        assertLe(
            address(frameImplementation).code.length,
            24_576,
            "migration implementation must remain deployable before EIP-7954"
        );
    }

    function test_kernelV33Migration_legacyUserOpStillValidAfterUpgrade() public {
        _assertLegacyUserOpValid(account, OWNER_KEY);
    }

    function test_kernelV33Migration_legacyUserOpRejectsWrongOwnerAfterUpgrade() public {
        _assertLegacyUserOpRejected(account, 0xBAD4337);
    }

    function test_kernelV33Migration_rejectsUnsupportedRootValidator() public {
        uint256 otherOwnerKey = 0xB0B8141;
        address otherOwner = vm.addr(otherOwnerKey);
        ECDSAValidator otherValidator = new ECDSAValidator();
        bytes memory initialization = _initialization(otherValidator, otherOwner);
        address unsupported =
            kernelFactory.createAccount(initialization, keccak256("kernel-v3.3-unsupported-root"));
        _upgrade(unsupported, address(frameImplementation));

        IFrameVm.FrameTx memory ctx = verifyContext(unsupported, SCOPE_BOTH, bytes32(0));
        ctx.frames[0].data = validationCalldata(0);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = secpSig(otherOwner);
        assertRefusesFrame(
            unsupported, ctx, "a different Kernel root profile must not inherit EIP-8141 authority"
        );

        // The rejection is Frame-specific: the account's original 4337 root is
        // still installed and valid after the same implementation upgrade.
        _assertLegacyUserOpValid(unsupported, otherOwnerKey);
    }

    function test_kernelV33Migration_rejectsRootWithExecutionHook() public {
        uint256 hookedOwnerKey = 0xB0B8142;
        address hookedOwner = vm.addr(hookedOwnerKey);
        bytes memory initialization = _initializationWithHook(
            ecdsaValidator,
            hookedOwner,
            IHook(address(ecdsaValidator)),
            abi.encodePacked(hex"00", hookedOwner)
        );
        address hooked =
            kernelFactory.createAccount(initialization, keccak256("kernel-v3.3-hooked-root"));
        _upgrade(hooked, address(frameImplementation));

        IFrameVm.FrameTx memory ctx = verifyContext(hooked, SCOPE_BOTH, bytes32(0));
        ctx.frames[0].data = validationCalldata(0);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = secpSig(hookedOwner);
        assertRefusesFrame(
            hooked, ctx, "Frame execution must not bypass an installed Kernel root execution hook"
        );

        // The migration refusal is Frame-specific. The hooked account's legacy
        // root-validator state remains installed behind the fallback path.
        assertEq(
            ecdsaValidator.ecdsaValidatorStorage(hooked),
            hookedOwner,
            "rejecting Frame approval must not alter the hooked legacy root"
        );
    }

    function test_kernelV33Migration_rejectsExplicitDigestSignature() public {
        IFrameVm.FrameTx memory ctx = verifyContext(account, SCOPE_BOTH, bytes32(uint256(0x8141)));
        ctx.frames[0].data = validationCalldata(0);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = secpSig(owner);
        ctx.signatures[0].msgHash = keccak256("not-the-canonical-frame-transaction");
        assertRefusesFrame(
            account, ctx, "an explicit digest must not be replayed as transaction approval"
        );
    }

    function test_kernelV33Migration_doesNotBroadenEcdsaRootToAnotherScheme() public {
        IFrameVm.FrameTx memory ctx = verifyContext(account, SCOPE_BOTH, bytes32(0));
        ctx.frames[0].data = validationCalldata(0);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = p256Sig(owner);
        assertRefusesFrame(
            account,
            ctx,
            "a same-address P256 key must not inherit the legacy secp256k1 root authority"
        );
    }

    function test_kernelV33Migration_rollbackRestoresLegacyOnlyMode() public {
        _assertLegacyUserOpValid(account, OWNER_KEY);

        _upgrade(account, address(legacyImplementation));
        assertEq(
            _implementationOf(account),
            address(legacyImplementation),
            "rollback must restore the original implementation"
        );
        assertEq(
            bytes32(ValidationId.unwrap(Kernel(payable(account)).rootValidator())),
            bytes32(ValidationId.unwrap(rootBeforeMigration)),
            "rollback must retain the original root"
        );
        assertEq(
            ecdsaValidator.ecdsaValidatorStorage(account),
            owner,
            "rollback must retain validator-owned account state"
        );
        assertTrue(
            Kernel(payable(account))
                .isModuleInstalled(MODULE_TYPE_EXECUTOR, MIGRATED_EXECUTOR, bytes("")),
            "rollback must retain the pre-migration executor module"
        );

        IFrameVm.FrameTx memory ctx = verifyContext(account, SCOPE_BOTH, bytes32(0));
        ctx.frames[0].data = validationCalldata(0);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = secpSig(owner);
        assertRefusesFrame(
            account, ctx, "the original Kernel implementation must not expose validate(uint256)"
        );

        _assertLegacyUserOpValid(account, OWNER_KEY);
    }

    function _initialization(ECDSAValidator validator, address initialOwner)
        internal
        pure
        returns (bytes memory)
    {
        return _initializationWithHook(validator, initialOwner, IHook(address(0)), bytes(""));
    }

    function _initializationWithHook(
        ECDSAValidator validator,
        address initialOwner,
        IHook hook,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        ValidationId root = ValidatorLib.validatorToIdentifier(IValidator(address(validator)));
        bytes[] memory initConfig = new bytes[](0);
        return abi.encodeCall(
            Kernel.initialize, (root, hook, abi.encodePacked(initialOwner), hookData, initConfig)
        );
    }

    function _upgrade(address kernel, address implementation) internal {
        vm.prank(ENTRY_POINT);
        Kernel(payable(kernel)).upgradeTo(implementation);
    }

    function _implementationOf(address kernel) internal view returns (address) {
        return address(uint160(uint256(vm.load(kernel, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _assertLegacyUserOpValid(address kernel, uint256 ownerKey) internal {
        ValidationData result = _legacyUserOpValidation(kernel, ownerKey);
        assertEq(
            address(uint160(ValidationData.unwrap(result))),
            address(0),
            "legacy 4337 signature must remain valid"
        );
    }

    function _assertLegacyUserOpRejected(address kernel, uint256 signerKey) internal {
        ValidationData result = _legacyUserOpValidation(kernel, signerKey);
        assertEq(
            address(uint160(ValidationData.unwrap(result))),
            address(1),
            "wrong owner must remain invalid on the legacy 4337 rail"
        );
    }

    function _legacyUserOpValidation(address kernel, uint256 signerKey)
        internal
        returns (ValidationData result)
    {
        bytes32 userOpHash = keccak256(abi.encode("kernel-v3.3-user-op", kernel));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, userOpHash);
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: kernel,
            nonce: 0,
            initCode: bytes(""),
            callData: bytes(""),
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: bytes(""),
            signature: abi.encodePacked(r, s, v)
        });

        vm.prank(ENTRY_POINT);
        result = Kernel(payable(kernel)).validateUserOp(userOp, userOpHash, 0);
    }
}
