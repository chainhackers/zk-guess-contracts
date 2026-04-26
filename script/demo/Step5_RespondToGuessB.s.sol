// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import "../../src/GuessGame.sol";
import {ProofIO} from "./ProofIO.sol";

/// @notice Demo: respond to guess B (correct guess) on a local-anvil deployment.
/// @dev Reads proof JSON from $PROOF_PATH (default /tmp/proof-b.json) — generate beforehand via:
///      `node scripts/generate-proof.js <secret> <salt> <guess> <maxNumber> <puzzleId> <guesser>`.
///      ProofIO already inherits forge-std/Script.sol; no need to inherit Script directly.
contract Step5_RespondToGuessB is ProofIO {
    function run(address gameAddress, uint256 puzzleId, uint256 challengeId) external {
        GuessGame game = GuessGame(gameAddress);
        (
            uint256[2] memory proofA,
            uint256[2][2] memory proofB,
            uint256[2] memory proofC,
            uint256[6] memory pubSignals
        ) = _readProofFrom(vm.envOr("PROOF_PATH", string("/tmp/proof-b.json")));

        vm.startBroadcast();

        // Get puzzle and challenge info
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        IGuessGame.Challenge memory challenge = game.getChallenge(puzzleId, challengeId);

        // Calculate expected prize
        uint256 expectedPrize = puzzle.bounty + challenge.stake;

        // Get winner's balance before
        uint256 winnerBalanceBefore = challenge.guesser.balance;

        game.respondToChallenge(puzzleId, challengeId, proofA, proofB, proofC, pubSignals);

        // Get winner's balance after
        uint256 winnerBalanceAfter = challenge.guesser.balance;
        uint256 actualPrize = winnerBalanceAfter - winnerBalanceBefore;

        console.log("=== RESPONDED TO GUESS B ===");
        console.log("Puzzle ID:", puzzleId);
        console.log("Challenge ID:", challengeId);
        console.log("Result: CORRECT! WINNER!");
        console.log("Winner:", challenge.guesser);
        console.log("Prize won:", actualPrize);
        console.log("  - From bounty:", puzzle.bounty);
        console.log("  - From stake:", challenge.stake);
        console.log("  - Total prize:", expectedPrize);
        console.log("");
        console.log("Creator collateral returned to internal balance");
        console.log("GAME OVER - Puzzle solved!");

        vm.stopBroadcast();
    }
}
