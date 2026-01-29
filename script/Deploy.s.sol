// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
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

        // Deploy game with verifier address and treasury
        GuessGame game = new GuessGame(address(verifier), treasury);
        console.log("GuessGame deployed at:", address(game));
        console.log("Treasury address:", treasury);

        vm.stopBroadcast();
    }
}
