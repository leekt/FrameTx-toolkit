// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ValidationId, ValidationType} from "kernel-v3.3/types/Types.sol";
import {
    HOOK_MODULE_INSTALLED,
    VALIDATION_MANAGER_STORAGE_SLOT,
    VALIDATION_TYPE_VALIDATOR
} from "kernel-v3.3/types/Constants.sol";
import {ValidatorLib} from "kernel-v3.3/utils/ValidationTypeLib.sol";
import {ECDSAValidator} from "kernel-v3.3/validator/ECDSAValidator.sol";

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {IFrameAccount} from "./IFrameAccount.sol";

/// @title KernelV33FrameAccount
/// @notice Compact EIP-8141 shim for an existing Kernel v3.3 proxy with the
///         configured v3.3 ECDSAValidator as its unhooked root.
/// @dev The shim declares no storage. It handles only `validate(uint256)` and
///      delegates every other selector to the exact pre-migration Kernel
///      implementation, preserving the complete ERC-4337/ERC-7579 surface and
///      Kernel's existing upgrade/rollback path. Both configuration values are
///      immutable and live in implementation bytecode.
contract KernelV33FrameAccount is IFrameAccount {
    struct KernelValidationConfig {
        uint32 nonce;
        address hook;
    }

    /// Mirrors the prefix and validation-config mapping of Kernel v3.3's
    /// namespaced storage. It introduces no storage in this implementation.
    struct KernelValidationStorage {
        ValidationId rootValidator;
        uint32 currentNonce;
        uint32 validNonceFrom;
        mapping(ValidationId => KernelValidationConfig) validationConfig;
    }

    address public immutable legacyImplementation;
    ECDSAValidator public immutable frameRootValidator;

    error InvalidMigrationConfiguration();
    error UnsupportedRootValidator();
    error NoTrustedSignature();
    error NothingToApprove();

    constructor(address legacyImplementation_, ECDSAValidator frameRootValidator_) {
        if (
            legacyImplementation_ == address(0) || legacyImplementation_.code.length == 0
                || address(frameRootValidator_) == address(0)
        ) {
            revert InvalidMigrationConfiguration();
        }
        legacyImplementation = legacyImplementation_;
        frameRootValidator = frameRootValidator_;
    }

    /// @notice Approve this VERIFY frame with one canonical secp256k1 signature
    ///         from the owner already installed in Kernel v3.3's root validator.
    function validate(uint256 signatureIndex) external override {
        KernelValidationStorage storage validationStorage = _kernelValidationStorage();
        ValidationId root = validationStorage.rootValidator;
        if (
            ValidationType.unwrap(ValidatorLib.getType(root))
                    != ValidationType.unwrap(VALIDATION_TYPE_VALIDATOR)
                || address(ValidatorLib.getValidator(root)) != address(frameRootValidator)
                // Frame SENDER execution does not run Kernel's ERC-4337 execution
                // hook. Reject hooked roots instead of silently broadening them.
                || validationStorage.validationConfig[root].hook != HOOK_MODULE_INSTALLED
        ) {
            revert UnsupportedRootValidator();
        }

        // Preserve the existing ECDSA root exactly. A P256 entry that
        // happens to resolve to the same 20-byte value must not broaden policy.
        if (FrameTxLib.sigScheme(signatureIndex) != FrameTxLib.SCHEME_SECP256K1) {
            revert NoTrustedSignature();
        }
        if (!FrameTxLib.signedThisTx(signatureIndex)) revert NoTrustedSignature();

        address owner = frameRootValidator.ecdsaValidatorStorage(address(this));
        if (owner == address(0) || FrameTxLib.sigSigner(signatureIndex) != owner) {
            revert NoTrustedSignature();
        }

        uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
        FrameTxLib.approve(scope);
    }

    function _kernelValidationStorage()
        private
        pure
        returns (KernelValidationStorage storage validationStorage)
    {
        assembly {
            validationStorage.slot := VALIDATION_MANAGER_STORAGE_SLOT
        }
    }

    /// @dev Preserve every legacy Kernel selector, including validateUserOp,
    ///      module execution, ERC-1271, receive hooks, and upgradeTo.
    fallback() external payable {
        _delegateLegacy();
    }

    receive() external payable {
        _delegateLegacy();
    }

    function _delegateLegacy() private {
        address implementation = legacyImplementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
