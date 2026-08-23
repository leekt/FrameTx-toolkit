// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccountTestSuite} from "./AccountTestSuite.sol";
import {IFrameVm} from "./FrameTest.sol";

/// examples/03-solidity-owner-account, executed against the real opcodes.
contract OwnerAccountTest is AccountTestSuite {
    address constant ACCOUNT = address(0xACC0);
    address constant OWNER = address(0x0BEEF);
    address constant STRANGER = address(0xBAD);

    function setUp() public {
        deployAccount("OwnerAccount", ACCOUNT);
        vm.store(ACCOUNT, bytes32(0), bytes32(uint256(uint160(OWNER))));
    }

    function accountUnderTest() internal pure override returns (address) {
        return ACCOUNT;
    }

    function accountAuthorizationSignatures()
        internal
        pure
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = secpSig(OWNER);
    }

    /// The frame data must carry `validate(uint256)`. OwnerAccount has a `receive()`, so an
    /// empty-calldata call succeeds whoever signed, and every assertion built on one
    /// is vacuous -- hence `assertApprovesFrame` rather than `assertApproves`.
    function _ctx(address signer) internal pure returns (IFrameVm.FrameTx memory ctx) {
        ctx = verifyContext(ACCOUNT, SCOPE_BOTH, bytes32(0));
        ctx.frames[0].data = validationCalldata(0);
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = secpSig(signer);
    }

    function test_ownerApproves() public {
        assertApprovesFrame(ACCOUNT, _ctx(OWNER), "owner should approve");
    }

    function test_mldsaOwnerApproves() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.signatures[0] = mldsaSig(OWNER);
        assertApprovesFrame(
            ACCOUNT, ctx, "the generic owner policy must accept a native ML-DSA-44 identity"
        );
    }

    function test_strangerRefused() public {
        assertRefusesFrame(ACCOUNT, _ctx(STRANGER), "stranger must not approve");
    }
}
