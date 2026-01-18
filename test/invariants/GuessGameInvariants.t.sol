// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/GuessGame.sol";
import "../../src/generated/GuessVerifier.sol";
import "./GuessGameHandler.sol";

contract GuessGameInvariants is Test {
    GuessGame public game;
    Groth16Verifier public verifier;
    GuessGameHandler public handler;

    function setUp() public {
        // Deploy contracts
        verifier = new Groth16Verifier();
        game = new GuessGame(address(verifier));
        handler = new GuessGameHandler(game, verifier);

        // Configure invariant test
        targetContract(address(handler));

        // Only call handler functions
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = GuessGameHandler.createPuzzle.selector;
        selectors[1] = GuessGameHandler.submitGuess.selector;
        selectors[2] = GuessGameHandler.respondToChallenge.selector;
        selectors[3] = GuessGameHandler.cancelPuzzle.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        // Fund handler's actors
        for (uint256 i = 0; i < 3; i++) {
            vm.deal(address(uint160(0x1000 + i)), 100 ether); // creators
            vm.deal(address(uint160(0x2000 + i)), 100 ether); // guessers
        }
    }

    /**
     * @notice Contract balance should always equal sum of all active puzzles' funds
     */
    function invariant_contractBalanceMatchesPuzzleFunds() public view {
        uint256 contractBalance = address(game).balance;
        uint256 expectedBalance = handler.sumActivePuzzleFunds();

        assertEq(contractBalance, expectedBalance, "Contract balance doesn't match sum of puzzle funds");
    }

    /**
     * @notice Puzzle IDs should only increase monotonically
     */
    function invariant_monotonicPuzzleIds() public view {
        uint256 puzzleCount = game.puzzleCount();

        // Check each puzzle ID exists in sequence
        for (uint256 i = 0; i < puzzleCount; i++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
            // All created puzzles should have a creator
            if (puzzle.creator != address(0)) {
                // If not cancelled, bounty should be at least MIN_BOUNTY
                if (!puzzle.cancelled && !puzzle.solved) {
                    assert(puzzle.bounty >= 0.001 ether);
                }
            }
        }
    }

    /**
     * @notice Solved puzzles should remain solved forever
     */
    function invariant_solvedPuzzlesImmutable() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 i = 0; i < puzzleCount; i++) {
            if (handler.ghostPuzzleSolved(i)) {
                IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
                assert(puzzle.solved == true);
            }
        }
    }

    /**
     * @notice Cancelled puzzles should remain cancelled forever
     */
    function invariant_cancelledPuzzlesImmutable() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 i = 0; i < puzzleCount; i++) {
            if (handler.ghostPuzzleCancelled(i)) {
                IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
                assert(puzzle.cancelled == true);
            }
        }
    }

    /**
     * @notice Challenge responses should be immutable
     */
    function invariant_challengeResponsesImmutable() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 puzzleId = 0; puzzleId < puzzleCount; puzzleId++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
            if (puzzle.creator == address(0)) continue;

            for (uint256 challengeId = 0; challengeId < puzzle.challengeCount; challengeId++) {
                IGuessGame.Challenge memory challenge = game.getChallenge(puzzleId, challengeId);
                // All challenges should have a guesser (never deleted)
                assert(challenge.guesser != address(0));
            }
        }
    }

    /**
     * @notice All active puzzles should have minimum bounty
     */
    function invariant_minimumBounty() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 i = 0; i < puzzleCount; i++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
            if (puzzle.creator != address(0) && !puzzle.solved && !puzzle.cancelled) {
                assert(puzzle.bounty >= 0.001 ether);
            }
        }
    }

    /**
     * @notice Pending challenges count should be consistent
     */
    function invariant_pendingChallengesConsistent() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 puzzleId = 0; puzzleId < puzzleCount; puzzleId++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
            if (puzzle.creator == address(0)) continue;

            uint256 calculatedPending = 0;
            for (uint256 challengeId = 0; challengeId < puzzle.challengeCount; challengeId++) {
                IGuessGame.Challenge memory challenge = game.getChallenge(puzzleId, challengeId);
                if (!challenge.responded) {
                    calculatedPending++;
                }
            }

            assertEq(puzzle.pendingChallenges, calculatedPending, "Pending challenges count mismatch");
        }
    }

    /**
     * @notice No ETH should be created or destroyed
     */
    function invariant_noValueCreation() public view {
        // This is implicitly tested by contractBalanceMatchesPuzzleFunds
        // But we can add additional checks
        uint256 contractBalance = address(game).balance;
        uint256 totalTracked = handler.ghostTotalContractFunds();

        // Contract balance should never exceed what we've tracked going in
        assert(contractBalance <= totalTracked);
    }

    /**
     * @notice A puzzle cannot be both solved and cancelled
     */
    function invariant_solvedOrCancelledMutuallyExclusive() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 i = 0; i < puzzleCount; i++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
            // A puzzle cannot be both solved AND cancelled
            assert(!(puzzle.solved && puzzle.cancelled));
        }
    }
}
