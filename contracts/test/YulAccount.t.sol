// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";

// contracts/src/accounts/account.yul, executed against the real opcodes.
//
// The account reads the owner from slot 0, asks SIGPARAM for signature 0's
// resolved signer and msg, then approves only when the owner signed the
// canonical transaction hash.
contract YulAccountTest is FrameTest {
    address constant ACCOUNT = address(0xACC2);
    address constant OWNER = address(0x0BEEF);
    address constant STRANGER = address(0xBAD);

    // solc --strict-assembly --bin contracts/src/accounts/account.yul
    bytes constant RUNTIME = hex"5f5fb460025fb41580825f5414161560175760035f5faa5b5f5ffd";

    function setUp() public {
        vm.etch(ACCOUNT, RUNTIME);
        vm.store(ACCOUNT, bytes32(0), bytes32(uint256(uint160(OWNER))));
    }

    function _ctx(address signer) internal pure returns (IFrameVm.FrameTx memory ctx) {
        return _ctx(signer, bytes32(0));
    }

    function _ctx(address signer, bytes32 msgHash) internal pure returns (IFrameVm.FrameTx memory ctx) {
        ctx = verifyContext(ACCOUNT, SCOPE_BOTH, bytes32(0));
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = secpSig(signer);
        ctx.signatures[0].msgHash = msgHash;
    }

    function test_ownerApproves() public {
        assertApproves(ACCOUNT, _ctx(OWNER), "owner should approve");
    }

    /// A validly signed transaction from a key the account does not trust: the
    /// protocol accepts the signature, the account rejects the signer.
    function test_strangerRefused() public {
        assertRefuses(ACCOUNT, _ctx(STRANGER), "stranger must not approve");
    }

    /// The owner entry is otherwise valid and the canonical-hash control above
    /// approves; changing only msg to an explicit digest must remove authority.
    function test_explicitDigestFromOwnerRefused() public {
        assertRefuses(
            ACCOUNT,
            _ctx(OWNER, keccak256("not the transaction hash")),
            "an explicit-digest signature must not approve the frame list"
        );
    }

    /// The account asks for scope 3. A frame permitting only payment must make
    /// APPROVE revert, which is the protocol's subset rule doing its job.
    function test_scopeOutsideFrameFlagsRefused() public {
        IFrameVm.FrameTx memory ctx = _ctx(OWNER);
        ctx.approvableScopes = SCOPE_PAYMENT;
        assertRefuses(ACCOUNT, ctx, "scope 3 must not be granted when only payment is permitted");
    }
}
