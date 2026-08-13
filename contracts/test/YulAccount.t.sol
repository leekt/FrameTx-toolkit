// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";

// examples/02-yul-minimal-account, executed against the real opcodes.
//
// The account is 19 bytes: read the owner from slot 0, ask SIGPARAM for the
// resolved signer of signature 0, approve execution and payment if they match.
contract YulAccountTest is FrameTest {
    address constant ACCOUNT = address(0xACC2);
    address constant OWNER = address(0x0BEEF);
    address constant STRANGER = address(0xBAD);

    // solc --strict-assembly --bin examples/02-yul-minimal-account/account.yul
    bytes constant RUNTIME = hex"5f5fb4805f5403600f5760035f5faa5b5f5ffd";

    function setUp() public {
        vm.etch(ACCOUNT, RUNTIME);
        vm.store(ACCOUNT, bytes32(0), bytes32(uint256(uint160(OWNER))));
    }

    function _ctx(address signer) internal pure returns (IFrameVm.FrameTx memory ctx) {
        ctx = verifyContext(ACCOUNT, SCOPE_BOTH, bytes32(0));
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = secpSig(signer);
    }

    function test_ownerApproves() public {
        assertApproves(ACCOUNT, _ctx(OWNER), "owner should approve");
    }

    /// A validly signed transaction from a key the account does not trust: the
    /// protocol accepts the signature, the account rejects the signer.
    function test_strangerRefused() public {
        assertRefuses(ACCOUNT, _ctx(STRANGER), "stranger must not approve");
    }

    /// The account asks for scope 3. A frame permitting only payment must make
    /// APPROVE revert, which is the protocol's subset rule doing its job.
    function test_scopeOutsideFrameFlagsRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.approvableScopes = SCOPE_PAYMENT;
        assertRefuses(ACCOUNT, ctx, "scope 3 must not be granted when only payment is permitted");
    }
}
