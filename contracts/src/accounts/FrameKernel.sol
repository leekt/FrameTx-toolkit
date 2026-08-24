pragma solidity ^0.8.0;

import {FrameTxLib} from "../frame/FrameTxLib.sol";

/// Kernel should be the account that will be the cornerstone of every verification
/// It should have P256/K1 signature natively supported
/// @author taek<leekt216@gmail.com>
contract FrameKernel {
    error OnlySelf();
    error NotApproved();
    error NothingToApprove();

    mapping(address => bool) public approvedSigner;

    function validate(uint256 index) external {
        FrameTxLib.approve(_validationScope(index));
    }

    /// @dev All validation reads stay in a view function. `validate` itself cannot
    ///      be view because APPROVE mutates transaction-scoped approval/payment state.
    function _validationScope(uint256 index) private view returns (uint256 scope) {
        /// note : we don't need modularity in signature verification
        /// on Frame, address of signer represents both pubkey and signature type
        /// when scheme is K1, signer should be valid K1 pubkey(as usual)
        /// when scheme is P256, signer should be valid P256 pubkey calculated with keccak256(qx || qy)

        /// Note for future
        /// there are discussions around pure function frames, so i am not applying any policies at this point
        address signer = FrameTxLib.sigSigner(index);
        require(approvedSigner[signer], NotApproved());

        // Use the scope named by this frame: BOTH for self relay, EXECUTION when
        // a paymaster pays, or PAYMENT when this account pays for another sender.
        // APPROVE enforces the target/sender and subset rules for each case.
        scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
        if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
    }

    function onlySelf() external view {
        require(msg.sender == address(this), OnlySelf());
    }
}
