// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {FrameTxLib} from "./FrameTxLib.sol";

/// @title  FrameTxLibHarness
/// @author taek <leekt216@gmail.com>
/// @notice Test-only pass-through exposing FrameTxLib externally, so the forge
///         tests can execute every wrapper against the real opcodes. Not an
///         account; carries no policy.
contract FrameTxLibHarness {
    function txType() external view returns (uint256) {
        return FrameTxLib.txType();
    }

    function txNonce() external view returns (uint256) {
        return FrameTxLib.txNonce();
    }

    function txSender() external view returns (address) {
        return FrameTxLib.txSender();
    }

    function maxPriorityFeePerGas() external view returns (uint256) {
        return FrameTxLib.maxPriorityFeePerGas();
    }

    function maxFeePerGas() external view returns (uint256) {
        return FrameTxLib.maxFeePerGas();
    }

    function maxFeePerBlobGas() external view returns (uint256) {
        return FrameTxLib.maxFeePerBlobGas();
    }

    function maxCost() external view returns (uint256) {
        return FrameTxLib.maxCost();
    }

    function blobCount() external view returns (uint256) {
        return FrameTxLib.blobCount();
    }

    function sigHash() external view returns (bytes32) {
        return FrameTxLib.sigHash();
    }

    function frameCount() external view returns (uint256) {
        return FrameTxLib.frameCount();
    }

    function currentFrameIndex() external view returns (uint256) {
        return FrameTxLib.currentFrameIndex();
    }

    function signatureCount() external view returns (uint256) {
        return FrameTxLib.signatureCount();
    }

    function legacyNonce() external view returns (uint256) {
        return FrameTxLib.legacyNonce();
    }

    function nonceKeyCount() external view returns (uint256) {
        return FrameTxLib.nonceKeyCount();
    }

    function nonceKeysHash() external view returns (bytes32) {
        return FrameTxLib.nonceKeysHash();
    }

    function recentRootReferenceCount() external view returns (uint256) {
        return FrameTxLib.recentRootReferenceCount();
    }

    function firstNonceKey() external view returns (uint256) {
        return FrameTxLib.firstNonceKey();
    }

    function recentRootSourceId(uint256 i) external view returns (bytes32) {
        return FrameTxLib.recentRootSourceId(i);
    }

    function recentRootSlot(uint256 i) external view returns (uint256) {
        return FrameTxLib.recentRootSlot(i);
    }

    function recentRoot(uint256 i) external view returns (bytes32) {
        return FrameTxLib.recentRoot(i);
    }

    function frameTarget(uint256 i) external view returns (address) {
        return FrameTxLib.frameTarget(i);
    }

    function frameGasLimit(uint256 i) external view returns (uint256) {
        return FrameTxLib.frameGasLimit(i);
    }

    function frameMode(uint256 i) external view returns (uint256) {
        return FrameTxLib.frameMode(i);
    }

    function frameFlags(uint256 i) external view returns (uint256) {
        return FrameTxLib.frameFlags(i);
    }

    function frameDataLength(uint256 i) external view returns (uint256) {
        return FrameTxLib.frameDataLength(i);
    }

    function frameStatus(uint256 i) external view returns (uint256) {
        return FrameTxLib.frameStatus(i);
    }

    function frameAllowedScope(uint256 i) external view returns (uint256) {
        return FrameTxLib.frameAllowedScope(i);
    }

    function frameIsAtomicBatch(uint256 i) external view returns (bool) {
        return FrameTxLib.frameIsAtomicBatch(i);
    }

    function frameValue(uint256 i) external view returns (uint256) {
        return FrameTxLib.frameValue(i);
    }

    function frameDataLoad(uint256 i, uint256 offset) external view returns (bytes32) {
        return FrameTxLib.frameDataLoad(i, offset);
    }

    function frameDataSlice(uint256 i, uint256 offset, uint256 length)
        external
        view
        returns (bytes memory)
    {
        return FrameTxLib.frameDataSlice(i, offset, length);
    }

    function frameData(uint256 i) external view returns (bytes memory) {
        return FrameTxLib.frameData(i);
    }

    function isExpiryFrame(uint256 i) external view returns (bool) {
        return FrameTxLib.isExpiryFrame(i);
    }

    function expiryDeadline(uint256 i) external view returns (uint64) {
        return FrameTxLib.expiryDeadline(i);
    }

    function sigSigner(uint256 i) external view returns (address) {
        return FrameTxLib.sigSigner(i);
    }

    function sigScheme(uint256 i) external view returns (uint256) {
        return FrameTxLib.sigScheme(i);
    }

    function sigMsg(uint256 i) external view returns (bytes32) {
        return FrameTxLib.sigMsg(i);
    }

    function signedThisTx(uint256 i) external view returns (bool) {
        return FrameTxLib.signedThisTx(i);
    }

    function sigLength(uint256 i) external view returns (uint256) {
        return FrameTxLib.sigLength(i);
    }

    function sigDataSlice(uint256 i, uint256 offset, uint256 length)
        external
        view
        returns (bytes memory)
    {
        return FrameTxLib.sigDataSlice(i, offset, length);
    }

    function sigData(uint256 i) external view returns (bytes memory) {
        return FrameTxLib.sigData(i);
    }

    function traceBalanceDiffCount() external view returns (uint256) {
        return FrameTxLib.traceBalanceDiffCount();
    }

    function traceStorageDiffCount() external view returns (uint256) {
        return FrameTxLib.traceStorageDiffCount();
    }

    function traceDeploymentCount() external view returns (uint256) {
        return FrameTxLib.traceDeploymentCount();
    }

    function traceBalanceAccount(uint256 i) external view returns (address) {
        return FrameTxLib.traceBalanceAccount(i);
    }

    function traceBalanceBefore(uint256 i) external view returns (uint256) {
        return FrameTxLib.traceBalanceBefore(i);
    }

    function traceBalanceAfter(uint256 i) external view returns (uint256) {
        return FrameTxLib.traceBalanceAfter(i);
    }

    function traceStorageAccount(uint256 i) external view returns (address) {
        return FrameTxLib.traceStorageAccount(i);
    }

    function traceStorageKey(uint256 i) external view returns (uint256) {
        return FrameTxLib.traceStorageKey(i);
    }

    function traceStorageBefore(uint256 i) external view returns (uint256) {
        return FrameTxLib.traceStorageBefore(i);
    }

    function traceStorageAfter(uint256 i) external view returns (uint256) {
        return FrameTxLib.traceStorageAfter(i);
    }

    function traceDeployedAccount(uint256 i) external view returns (address) {
        return FrameTxLib.traceDeployedAccount(i);
    }

    function traceDeployedCodeHash(uint256 i) external view returns (bytes32) {
        return FrameTxLib.traceDeployedCodeHash(i);
    }

    function traceEventCount() external view returns (uint256) {
        return FrameTxLib.traceEventCount();
    }

    function traceEventEmitter(uint256 i) external view returns (address) {
        return FrameTxLib.traceEventEmitter(i);
    }

    function traceEventTopicCount(uint256 i) external view returns (uint256) {
        return FrameTxLib.traceEventTopicCount(i);
    }

    function traceEventTopic0(uint256 i) external view returns (bytes32) {
        return FrameTxLib.traceEventTopic0(i);
    }

    function traceEventTopic1(uint256 i) external view returns (bytes32) {
        return FrameTxLib.traceEventTopic1(i);
    }

    function traceEventTopic2(uint256 i) external view returns (bytes32) {
        return FrameTxLib.traceEventTopic2(i);
    }

    function traceEventTopic3(uint256 i) external view returns (bytes32) {
        return FrameTxLib.traceEventTopic3(i);
    }

    function traceEventDataLength(uint256 i) external view returns (uint256) {
        return FrameTxLib.traceEventDataLength(i);
    }

    function traceGasPreCharge() external view returns (uint256) {
        return FrameTxLib.traceGasPreCharge();
    }

    function traceGasPayer() external view returns (address) {
        return FrameTxLib.traceGasPayer();
    }

    function storageValueBefore(address account, uint256 key) external view returns (uint256) {
        return FrameTxLib.storageValueBefore(account, key);
    }

    function storageValueAfter(address account, uint256 key) external view returns (uint256) {
        return FrameTxLib.storageValueAfter(account, key);
    }

    function accountBalanceBefore(address account) external view returns (uint256) {
        return FrameTxLib.accountBalanceBefore(account);
    }

    function accountBalanceAfter(address account) external view returns (uint256) {
        return FrameTxLib.accountBalanceAfter(account);
    }

    function accountCodeHashBefore(address account) external view returns (bytes32) {
        return FrameTxLib.accountCodeHashBefore(account);
    }

    function accountCodeHashAfter(address account) external view returns (bytes32) {
        return FrameTxLib.accountCodeHashAfter(account);
    }

    function accountStorageDiffCount(address account) external view returns (uint256) {
        return FrameTxLib.accountStorageDiffCount(account);
    }

    function accountStorageDiffIndex(address account, uint256 localIndex)
        external
        view
        returns (uint256)
    {
        return FrameTxLib.accountStorageDiffIndex(account, localIndex);
    }

    function accountEventCount(address account) external view returns (uint256) {
        return FrameTxLib.accountEventCount(account);
    }

    function accountEventIndex(address account, uint256 localIndex)
        external
        view
        returns (uint256)
    {
        return FrameTxLib.accountEventIndex(account, localIndex);
    }

    function accountDiffFlags(address account) external view returns (uint256) {
        return FrameTxLib.accountDiffFlags(account);
    }

    function eventDataSlice(uint256 eventIndex, uint256 dataOffset, uint256 length)
        external
        view
        returns (bytes memory)
    {
        return FrameTxLib.eventDataSlice(eventIndex, dataOffset, length);
    }

    function eventData(uint256 eventIndex) external view returns (bytes memory) {
        return FrameTxLib.eventData(eventIndex);
    }

    function approve(uint256 scope) external {
        FrameTxLib.approve(scope);
    }

    function approveWithData(uint256 scope, bytes calldata data) external {
        FrameTxLib.approve(scope, data);
    }
}
