// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import "../src/Rewards.sol";
import "../src/generated/GuessVerifier.sol";

contract DeployScript is Script {
    /// @notice Deploys Verifier + Rewards + GuessGame (proxy); Rewards is GuessGame's treasury.
    /// @dev Forfeit collateral flows into Rewards; owner publishes merkle roots to distribute.
    function run() external {
        vm.startBroadcast();

        Groth16Verifier verifier = new Groth16Verifier();
        console.log("GuessVerifier deployed at:", address(verifier));

        Rewards rewards = new Rewards(msg.sender);
        console.log("Rewards deployed at:", address(rewards));

        GuessGame impl = new GuessGame();
        console.log("GuessGame implementation deployed at:", address(impl));

        bytes memory initData = abi.encodeCall(GuessGame.initialize, (address(verifier), address(rewards), msg.sender));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        console.log("GuessGame proxy deployed at:", address(proxy));
        console.log("Treasury (Rewards) address:", address(rewards));

        vm.stopBroadcast();
    }
}
