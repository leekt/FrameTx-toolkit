// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Create2FactoryLib} from "../src/eips/Create2FactoryLib.sol";

contract Probe {
    uint256 public immutable x;

    constructor(uint256 _x) payable {
        x = _x;
    }
}

/// The EIP-7997 factory needs no frame opcodes; these tests run under stock
/// Foundry. Anvil and the Foundry test EVM both carry the factory account, but
/// the etch below makes the suite independent of that injection.
contract Create2FactoryLibTest is Test {
    /// The factory runtime specified by EIP-7997 (the classic deterministic
    /// deployment proxy).
    bytes constant FACTORY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    function setUp() public {
        if (Create2FactoryLib.FACTORY.code.length == 0) {
            vm.etch(Create2FactoryLib.FACTORY, FACTORY_RUNTIME);
        }
    }

    function test_computeAddress_matchesStandardCreate2Derivation() public pure {
        bytes32 salt = keccak256("some salt");
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(Probe).creationCode, uint256(7)));
        assertEq(
            Create2FactoryLib.computeAddress(salt, initCodeHash),
            vm.computeCreate2Address(salt, initCodeHash, Create2FactoryLib.FACTORY)
        );
    }

    function test_deploy_createsAtComputedAddress() public {
        bytes32 salt = bytes32(uint256(1));
        bytes memory initCode = abi.encodePacked(type(Probe).creationCode, uint256(42));
        address predicted = Create2FactoryLib.computeAddress(salt, keccak256(initCode));

        address deployed = Create2FactoryLib.deploy(salt, initCode);

        assertEq(deployed, predicted);
        assertEq(Probe(deployed).x(), 42);
    }

    function test_deploy_forwardsValue() public {
        bytes32 salt = bytes32(uint256(2));
        bytes memory initCode = abi.encodePacked(type(Probe).creationCode, uint256(0));
        vm.deal(address(this), 1 ether);

        address deployed = Create2FactoryLib.deploy(salt, initCode, 1 ether);

        assertEq(deployed.balance, 1 ether);
    }

    function test_deploy_revertsOnReusedSalt() public {
        bytes32 salt = bytes32(uint256(3));
        bytes memory initCode = abi.encodePacked(type(Probe).creationCode, uint256(0));
        Create2FactoryLib.deploy(salt, initCode);

        vm.expectRevert(Create2FactoryLib.DeploymentFailed.selector);
        this.deployExternal(salt, initCode);
    }

    function test_deploy_revertsOnRevertingInitcode() public {
        // Initcode that always reverts: PUSH0 PUSH0 REVERT.
        vm.expectRevert(Create2FactoryLib.DeploymentFailed.selector);
        this.deployExternal(bytes32(uint256(4)), hex"5f5ffd");
    }

    /// expectRevert needs an external call frame; library calls inline.
    function deployExternal(bytes32 salt, bytes memory initCode) external returns (address) {
        return Create2FactoryLib.deploy(salt, initCode);
    }
}
