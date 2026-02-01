// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/GuessGame.sol";

contract Step1_CreatePuzzle is Script {
    // Puzzle parameters
    bytes32 constant COMMITMENT = 0x1d869fb8246b6131377493aaaf1cc16a8284d4aedcb7277079df35d0d1d552d1; // number=42, salt=123
    uint256 constant TOTAL_AMOUNT = 0.002 ether; // bounty + collateral (split 1:1)
    uint256 constant STAKE_REQUIRED = 0.0005 ether;
    uint256 constant MAX_NUMBER = 100;

    function run(address gameAddress) external {
        GuessGame game = GuessGame(gameAddress);

        vm.startBroadcast();

        uint256 puzzleId = game.createPuzzle{value: TOTAL_AMOUNT}(COMMITMENT, STAKE_REQUIRED, MAX_NUMBER);

        console.log("=== PUZZLE CREATED ===");
        console.log("Puzzle ID:", puzzleId);
        console.log("Creator:", msg.sender);
        console.log("Total Amount:", TOTAL_AMOUNT);
        console.log("Bounty:", TOTAL_AMOUNT / 2);
        console.log("Collateral:", TOTAL_AMOUNT / 2);
        console.log("Stake Required:", STAKE_REQUIRED);
        console.log("Secret: 42 (commitment stored on-chain)");

        vm.stopBroadcast();
    }
}
