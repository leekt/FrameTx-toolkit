// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {vFrame} from "../src/vFrame.sol";
import {VFrameAccount} from "../src/VFrameAccount.sol";
import {VFrameTypes as T} from "../src/IVFrame.sol";

contract VFrameCounter {
    uint256 public number;
    address public lastCaller;
    mapping(address caller => uint256 count) public calls;

    function increment() external {
        ++number;
        lastCaller = msg.sender;
        ++calls[msg.sender];
    }
}

/// @notice Deploys a fresh demo and relays an owner-signed operation using normal transactions.
/// @dev The relayer funds deployments plus a 0.01 ETH deposit. The owner needs no ETH.
contract VFrameDemo is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("VFRAME_OWNER_KEY");
        uint256 relayerKey = vm.envUint("VFRAME_RELAYER_KEY");
        vm.startBroadcast(relayerKey);
        vFrame entryPoint = new vFrame();
        VFrameAccount account = new VFrameAccount(entryPoint, vm.addr(ownerKey));
        VFrameCounter counter = new VFrameCounter();
        entryPoint.depositTo{value: 0.01 ether}(address(account));
        vm.stopBroadcast();

        T.Transaction memory transaction;
        transaction.sender = address(account);
        transaction.nonceKeys = new uint256[](1);
        transaction.nonce = entryPoint.nonces(address(account), 0);
        transaction.overheadGasLimit = 200_000;
        transaction.maxPriorityFeePerGas = 1 gwei;
        transaction.maxFeePerGas = 2 * block.basefee + transaction.maxPriorityFeePerGas;
        transaction.frames = new T.Frame[](3);
        transaction.frames[0] = T.Frame(T.VERIFY, T.BOTH, address(0), 200_000, 0, "");
        transaction.frames[1] = T.Frame(
            T.SENDER, 0, address(counter), 200_000, 0, abi.encodeCall(VFrameCounter.increment, ())
        );
        transaction.frames[2] = T.Frame(
            T.DEFAULT, 0, address(counter), 200_000, 0, abi.encodeCall(VFrameCounter.increment, ())
        );
        transaction.authorizations = new bytes[](3);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerKey, entryPoint.getTransactionHash(transaction));
        transaction.authorizations[0] = abi.encodePacked(r, s, v);

        vm.startBroadcast(relayerKey);
        // Reserve the signed call budgets, not just the gas actually used in simulation.
        entryPoint.handle{gas: 1_000_000}(transaction);
        vm.stopBroadcast();

        require(
            counter.number() == 2 && counter.calls(address(account)) == 1
                && counter.calls(address(entryPoint.defaultCaller())) == 1
                && counter.lastCaller() == address(entryPoint.defaultCaller()),
            "execution or caller routing failed"
        );
        require(entryPoint.nonces(address(account), 0) == 1, "nonce not consumed");
        uint256 charge = entryPoint.deposits(vm.addr(relayerKey));
        require(
            charge <= entryPoint.getGasQuote(transaction).maxCost, "charge exceeded reservation"
        );
        require(entryPoint.deposits(address(account)) + charge == 0.01 ether, "unbalanced payment");
        console2.log("vFrame:", address(entryPoint));
        console2.log("DEFAULT caller:", address(entryPoint.defaultCaller()));
        console2.log("Account:", address(account));
        console2.log("Counter:", address(counter));
    }
}
