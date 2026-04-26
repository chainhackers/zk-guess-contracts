// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import "../../src/GuessGame.sol";
import {ProofIO} from "./ProofIO.sol";

/// @notice Demo: respond to guess A on a local-anvil deployment.
/// @dev Reads proof JSON from $PROOF_PATH (default /tmp/proof-a.json) — generate beforehand via:
///      `node scripts/generate-proof.js <secret> <salt> <guess> <maxNumber> <puzzleId> <guesser>`.
///      ProofIO already inherits forge-std/Script.sol; no need to inherit Script directly.
contract Step3_RespondToGuessA is ProofIO {
    function run(address gameAddress, uint256 puzzleId, uint256 challengeId) external {
        GuessGame game = GuessGame(gameAddress);
        (
            uint256[2] memory proofA,
            uint256[2][2] memory proofB,
            uint256[2] memory proofC,
            uint256[6] memory pubSignals
        ) = _readProofFrom(vm.envOr("PROOF_PATH", string("/tmp/proof-a.json")));

        vm.startBroadcast();

        // Get puzzle state before response
        IGuessGame.Puzzle memory puzzleBefore = game.getPuzzle(puzzleId);

        game.respondToChallenge(puzzleId, challengeId, proofA, proofB, proofC, pubSignals);

        // Get puzzle state after response
        IGuessGame.Puzzle memory puzzleAfter = game.getPuzzle(puzzleId);

        console.log("=== RESPONDED TO GUESS A ===");
        console.log("Puzzle ID:", puzzleId);
        console.log("Challenge ID:", challengeId);
        console.log("Result: INCORRECT");
        console.log("Pending challenges:", puzzleAfter.pendingChallenges);
        console.log("Bounty:", puzzleAfter.bounty);

        vm.stopBroadcast();
    }
}
