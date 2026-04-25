// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/GuessGame.sol";

/// @notice Demo: respond to guess B (correct guess) on a local-anvil deployment.
/// @dev Reads proof JSON from $PROOF_PATH (default /tmp/proof-b.json) — generate beforehand via:
///      `node scripts/generate-proof.js <secret> <salt> <guess> <maxNumber> <puzzleId> <guesser>`.
contract Step5_RespondToGuessB is Script {
    function _readProof()
        internal
        view
        returns (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[6] memory pubSignals)
    {
        string memory path = vm.envOr("PROOF_PATH", string("/tmp/proof-b.json"));
        string memory json = vm.readFile(path);
        pA[0] = vm.parseJsonUint(json, ".pA[0]");
        pA[1] = vm.parseJsonUint(json, ".pA[1]");
        pB[0][0] = vm.parseJsonUint(json, ".pB[0][0]");
        pB[0][1] = vm.parseJsonUint(json, ".pB[0][1]");
        pB[1][0] = vm.parseJsonUint(json, ".pB[1][0]");
        pB[1][1] = vm.parseJsonUint(json, ".pB[1][1]");
        pC[0] = vm.parseJsonUint(json, ".pC[0]");
        pC[1] = vm.parseJsonUint(json, ".pC[1]");
        for (uint256 i = 0; i < 6; i++) {
            pubSignals[i] = vm.parseJsonUint(json, string.concat(".pubSignals[", vm.toString(i), "]"));
        }
    }

    function run(address gameAddress, uint256 puzzleId, uint256 challengeId) external {
        GuessGame game = GuessGame(gameAddress);
        (
            uint256[2] memory proofA,
            uint256[2][2] memory proofB,
            uint256[2] memory proofC,
            uint256[6] memory pubSignals
        ) = _readProof();

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
