// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/GuessGame.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        GuessGame game = new GuessGame();
        
        console.log("GuessGame deployed at:", address(game));
        
        vm.stopBroadcast();
    }
}