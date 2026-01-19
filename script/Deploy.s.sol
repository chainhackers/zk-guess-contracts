// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/GuessGame.sol";
import "../src/generated/GuessVerifier.sol";

contract DeployScript is Script {
    function run() external {
        // When using --account, forge handles the key
        vm.startBroadcast();

        // Deploy verifier first
        Groth16Verifier verifier = new Groth16Verifier();
        console.log("GuessVerifier deployed at:", address(verifier));

        // Deploy game with verifier address
        GuessGame game = new GuessGame(address(verifier));
        console.log("GuessGame deployed at:", address(game));

        vm.stopBroadcast();
    }
}
