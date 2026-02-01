// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import "../src/generated/GuessVerifier.sol";

contract DeployScript is Script {
    function run() external {
        // Treasury address from environment or use deployer as fallback
        address treasury = vm.envOr("TREASURY_ADDRESS", msg.sender);

        // When using --account, forge handles the key
        vm.startBroadcast();

        // Deploy verifier first
        Groth16Verifier verifier = new Groth16Verifier();
        console.log("GuessVerifier deployed at:", address(verifier));

        // Deploy implementation
        GuessGame impl = new GuessGame();
        console.log("GuessGame implementation deployed at:", address(impl));

        // Deploy proxy with initialize call
        bytes memory initData = abi.encodeCall(GuessGame.initialize, (address(verifier), treasury));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        console.log("GuessGame proxy deployed at:", address(proxy));
        console.log("Treasury address:", treasury);

        vm.stopBroadcast();
    }
}
