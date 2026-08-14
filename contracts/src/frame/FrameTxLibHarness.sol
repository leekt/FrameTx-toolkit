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

    function maxCost() external view returns (uint256) {
        return FrameTxLib.maxCost();
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

    function approve(uint256 scope) external {
        FrameTxLib.approve(scope);
    }

    function approveWithData(uint256 scope, bytes calldata data) external {
        FrameTxLib.approve(scope, data);
    }
}
