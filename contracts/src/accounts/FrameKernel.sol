pragma solidity ^0.8.0;

import {FrameTxLib} from "../frame/FrameTxLib.sol";
import {WebAuthn} from "solady/utils/WebAuthn.sol";
import {Base64} from "solady/utils/Base64.sol";

interface IFormatter {
    function format(bytes32 txHash, bytes calldata data, uint256 index)
        external
        view
        returns (bytes32);
}

contract WebAuthNFormatter is IFormatter {
    function format(bytes32 txHash, bytes calldata data, uint256 index)
        external
        view
        override
        returns (bytes32 messageHash)
    {
        /*
           bytes memory challenge,
           bool requireUserVerification,
           WebAuthnAuth memory auth,
         */
        string memory encoded = Base64.encode(abi.encode(txHash), true, true);
        WebAuthn.WebAuthnAuth memory auth = WebAuthn.tryDecodeAuth(data);
        bool result;
        // NOTE: marking this false for now
        bool requireUserVerification = false;
        /// @solidity memory-safe-assembly
        assembly {
            let clientDataJSON := mload(add(auth, 0x20))
            let n := mload(clientDataJSON) // `clientDataJSON`'s length.
            let o := add(clientDataJSON, 0x20) // Start of `clientData`'s bytes.
            {
                let c := mload(add(auth, 0x40)) // Challenge index in `clientDataJSON`.
                let t := mload(add(auth, 0x60)) // Type index in `clientDataJSON`.
                let l := mload(encoded) // Cache `encoded`'s length.
                let q := add(l, 0x0d) // Length of `encoded` prefixed with '"challenge":"'.
                mstore(encoded, shr(152, '"challenge":"')) // Temp prefix with '"challenge":"'.
                result := and(
                    // 11. Verify JSON's type. Also checks for possible addition overflows.
                    and(
                        eq(shr(88, mload(add(o, t))), shr(88, '"type":"webauthn.get"')),
                        lt(shr(128, or(t, c)), lt(add(0x14, t), n))
                    ),
                    // 12. Verify JSON's challenge. Includes a check for the closing '"'.
                    and(
                        eq(keccak256(add(o, c), q), keccak256(add(encoded, 0x13), q)),
                        and(eq(byte(0, mload(add(add(o, c), q))), 34), lt(add(q, c), n))
                    )
                )
                mstore(encoded, l) // Restore `encoded`'s length, in case of string interning.
            }
            // Skip 13., 14., 15.
            let l := mload(mload(auth)) // Length of `authenticatorData`.
            // 16. Verify that the "User Present" flag is set (bit 0).
            // 17. Verify that the "User Verified" flag is set (bit 2), if required.
            // See: https://www.w3.org/TR/webauthn-2/#flags.
            let u := or(1, shl(2, iszero(iszero(requireUserVerification))))
            result := and(and(result, gt(l, 0x20)), eq(and(mload(add(mload(auth), 0x21)), u), u))
            if result {
                let p := add(mload(auth), 0x20) // Start of `authenticatorData`'s bytes.
                let e := add(p, l) // Location of the word after `authenticatorData`.
                let w := mload(e) // Cache the word after `authenticatorData`.
                // 19. Compute `sha256(clientDataJSON)`.
                // 20. Compute `sha256(authenticatorData ‖ sha256(clientDataJSON))`.
                // forgefmt: disable-next-item
                messageHash := mload(staticcall(gas(),
                    shl(1, staticcall(gas(), 2, o, n, e, 0x20)), p, add(l, 0x20), 0x01, 0x20))
                mstore(e, w) // Restore the word after `authenticatorData`, in case of reuse.
                // `returndatasize()` is `0x20` on `sha256` success, and `0x00` otherwise.
                if iszero(returndatasize()) { invalid() }
            }
        }
        if (!result) {
            // return, maybe we should use something else?
            return bytes32(0);
        }
    }
}

/// Kernel should be the account that will be the cornerstone of every verification
/// It should have P256/K1 signature natively supported
/// @author taek<leekt216@gmail.com>
contract FrameKernel {
    error OnlySelf();
    error NotApproved();
    error NothingToApprove();
    error InvalidMsg();

    mapping(address => IFormatter) public formatter;

    function validate(uint256 index, bytes calldata data) external {
        FrameTxLib.approve(_validationScope(index, data));
    }

    /// @dev All validation reads stay in a view function. `validate` itself cannot
    ///      be view because APPROVE mutates transaction-scoped approval/payment state.
    function _validationScope(uint256 index, bytes calldata data)
        private
        view
        returns (uint256 scope)
    {
        /// note : we don't need modularity in signature verification
        /// on Frame, address of signer represents both pubkey and signature type
        /// when scheme is K1, signer should be valid K1 pubkey(as usual)
        /// when scheme is P256, signer should be valid P256 pubkey calculated with keccak256(qx || qy)

        /// Note for future
        /// there are discussions around pure function frames, so i am not applying any policies at this point
        address signer = FrameTxLib.sigSigner(index);
        IFormatter fmt = formatter[signer];
        require(address(fmt) != address(0), NotApproved());
        if (address(fmt) != address(1)) {
            require(
                FrameTxLib.sigMsg(index) == fmt.format(FrameTxLib.sigHash(), data, index),
                InvalidMsg()
            );
        } else {
            require(FrameTxLib.signedThisTx(index), InvalidMsg());
        }

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
