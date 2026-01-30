// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/GuessGame.sol";

contract Step2_SubmitGuessA is Script {
    uint256 constant GUESS = 50; // Wrong guess
    uint256 constant STAKE = 0.0005 ether;

    function run(address gameAddress, uint256 puzzleId) external {
        GuessGame game = GuessGame(gameAddress);

        vm.startBroadcast();

        uint256 challengeId = game.submitGuess{value: STAKE}(puzzleId, GUESS);

        console.log("=== GUESS A SUBMITTED ===");
        console.log("Challenge ID:", challengeId);
        console.log("Guesser A:", msg.sender);
        console.log("Guess:", GUESS, "(wrong)");
        console.log("Stake:", STAKE);

        vm.stopBroadcast();
    }
}
