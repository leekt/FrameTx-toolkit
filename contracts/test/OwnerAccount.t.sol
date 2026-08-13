// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";

/// examples/03-solidity-owner-account, executed against the real opcodes.
contract OwnerAccountTest is FrameTest {
    address constant ACCOUNT = address(0xACC0);
    address constant OWNER = address(0x0BEEF);

    function setUp() public {
        deployAccount("OwnerAccount", ACCOUNT);
        vm.store(ACCOUNT, bytes32(0), bytes32(uint256(uint160(OWNER))));
    }

    function test_ownerApproves() public {
        IFrameVm.FrameTx memory ctx = verifyContext(ACCOUNT, SCOPE_BOTH, bytes32(0));
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = secpSig(OWNER);
        assertApproves(ACCOUNT, ctx, "owner should approve");
    }
}
