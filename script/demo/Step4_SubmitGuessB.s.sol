// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/GuessGame.sol";

contract Step4_SubmitGuessB is Script {
    uint256 constant GUESS = 42; // Correct guess!
    uint256 constant STAKE = 0.0005 ether;

    function run(address gameAddress, uint256 puzzleId) external {
        GuessGame game = GuessGame(gameAddress);

        vm.startBroadcast();

        // Check puzzle state before guess
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);

        uint256 challengeId = game.submitGuess{value: STAKE}(puzzleId, GUESS);

        console.log("=== GUESS B SUBMITTED ===");
        console.log("Puzzle ID:", puzzleId);
        console.log("Challenge ID:", challengeId);
        console.log("Guesser B:", msg.sender);
        console.log("Guess:", GUESS, "(correct!)");
        console.log("Stake:", STAKE);
        console.log("Current bounty:", puzzle.bounty);
        console.log("Pending challenges:", puzzle.pendingChallenges + 1);

        vm.stopBroadcast();
    }
}
