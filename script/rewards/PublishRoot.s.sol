// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {Rewards} from "../../src/Rewards.sol";

/// @notice Publish a precomputed merkle root to the Rewards contract for a new epoch.
/// @dev Run with: ROOT=0x... REWARDS_ADDR=0x... forge script ... --account deployer --broadcast
contract PublishRootScript is Script {
    function run() external {
        bytes32 root = vm.envBytes32("ROOT");
        address rewardsAddr = vm.envAddress("REWARDS_ADDR");

        require(root != bytes32(0), "ROOT must be non-zero");
        require(rewardsAddr.code.length > 0, "REWARDS_ADDR has no code");

        Rewards rewards = Rewards(payable(rewardsAddr));

        uint256 prevEpoch = rewards.currentEpoch();
        uint256 expectedEpoch = vm.envOr("EXPECTED_EPOCH", uint256(0));
        require(
            expectedEpoch == 0 || expectedEpoch == prevEpoch + 1, "EXPECTED_EPOCH mismatch (race with another publish?)"
        );

        vm.startBroadcast();
        uint256 epoch = rewards.publishRoot(root);
        vm.stopBroadcast();

        console.log("Rewards address:", rewardsAddr);
        console.log("Previous currentEpoch:", prevEpoch);
        console.log("Published epoch:", epoch);
        console.log("Root:");
        console.logBytes32(root);
    }
}
