// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {vFrame} from "../src/vFrame.sol";
import {VFrameAccountFactory} from "../src/VFrameAccountFactory.sol";

contract DeployVFrame is Script {
    address public constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant VFRAME_SALT = keccak256("vFrame");
    bytes32 public constant FACTORY_SALT = keccak256("VFrameAccountFactory");

    function run() external {
        require(block.chainid == 11155111, "Sepolia only");
        (vFrame entryPoint, VFrameAccountFactory factory) = predict();
        _writeEnv(entryPoint, factory);
        require(CREATE2_PROXY.code.length != 0, "CREATE2 proxy not deployed");
        vm.startBroadcast();
        // Foundry routes salted creations in a broadcast through the configured CREATE2 proxy.
        if (address(entryPoint).code.length == 0) {
            require(
                address(new vFrame{salt: VFRAME_SALT}()) == address(entryPoint),
                "Unexpected CREATE2 proxy"
            );
        }
        if (address(factory).code.length == 0) {
            require(
                address(new VFrameAccountFactory{salt: FACTORY_SALT}(entryPoint))
                    == address(factory),
                "Unexpected CREATE2 proxy"
            );
        }
        vm.stopBroadcast();
        _checkDeployment(entryPoint, factory);
        console2.log("vFrame", address(entryPoint));
        console2.log("DEFAULT caller", address(entryPoint.defaultCaller()));
        console2.log("VFrameAccountFactory", address(factory));
    }

    /// @notice Addresses depend on the proxy, fixed salts and compiled init code, never the wallet.
    function predict() public pure returns (vFrame entryPoint, VFrameAccountFactory factory) {
        entryPoint = vFrame(
            vm.computeCreate2Address(
                VFRAME_SALT, keccak256(type(vFrame).creationCode), CREATE2_PROXY
            )
        );
        factory = VFrameAccountFactory(
            vm.computeCreate2Address(
                FACTORY_SALT,
                keccak256(
                    abi.encodePacked(
                        type(VFrameAccountFactory).creationCode, abi.encode(entryPoint)
                    )
                ),
                CREATE2_PROXY
            )
        );
    }

    /// @dev CREATE2 addresses are known before broadcast, including during a dry run.
    function _writeEnv(vFrame entryPoint, VFrameAccountFactory factory) internal {
        string memory path = string.concat(vm.projectRoot(), "/../web/.env.local");
        string memory contents;
        if (vm.exists(path)) {
            string[] memory lines = vm.split(vm.readFile(path), "\n");
            for (uint256 i; i < lines.length; ++i) {
                string memory key = vm.trim(vm.split(lines[i], "=")[0]);
                key = vm.replace(key, "export ", "");
                if (
                    keccak256(bytes(key)) != keccak256("NEXT_PUBLIC_VFRAME_ADDRESS")
                        && keccak256(bytes(key)) != keccak256("NEXT_PUBLIC_FACTORY_ADDRESS")
                        && (i + 1 < lines.length || bytes(lines[i]).length != 0)
                ) contents = string.concat(contents, lines[i], "\n");
            }
        }
        vm.writeFile(
            path,
            string.concat(
                contents,
                "NEXT_PUBLIC_VFRAME_ADDRESS=",
                vm.toString(address(entryPoint)),
                "\n",
                "NEXT_PUBLIC_FACTORY_ADDRESS=",
                vm.toString(address(factory)),
                "\n"
            )
        );
        console2.log("Updated web/.env.local");
    }

    function _checkDeployment(vFrame entryPoint, VFrameAccountFactory factory) internal view {
        require(address(entryPoint).code.length != 0, "vFrame not deployed on this chain");
        require(address(factory).code.length != 0, "Factory not deployed on this chain");
        require(address(factory.entryPoint()) == address(entryPoint), "Factory EntryPoint mismatch");
        require(address(entryPoint.defaultCaller()).code.length != 0, "DEFAULT caller not deployed");
    }
}
