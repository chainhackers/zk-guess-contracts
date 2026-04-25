// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/GuessGame.sol";

/// @notice Demo: respond to guess A on a local-anvil deployment.
/// @dev Reads proof JSON from $PROOF_PATH (default /tmp/proof-a.json) — generate beforehand via:
///      `node scripts/generate-proof.js <secret> <salt> <guess> <maxNumber> <puzzleId> <guesser>`.
///      Hardcoded proofs were dropped at the v2 circuit cutover (puzzleId+guesser binding).
contract Step3_RespondToGuessA is Script {
    function _readProof()
        internal
        view
        returns (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[6] memory pubSignals)
    {
        string memory path = vm.envOr("PROOF_PATH", string("/tmp/proof-a.json"));
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
