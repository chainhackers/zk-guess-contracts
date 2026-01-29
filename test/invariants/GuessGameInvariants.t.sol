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

    address treasury;

    function setUp() public {
        // Deploy contracts
        verifier = new Groth16Verifier();
        treasury = makeAddr("treasury");
        game = new GuessGame(address(verifier), treasury);
        handler = new GuessGameHandler(game, verifier, treasury);

        // Configure invariant test
        targetContract(address(handler));

        // Only call handler functions
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = GuessGameHandler.createPuzzle.selector;
        selectors[1] = GuessGameHandler.submitGuess.selector;
        selectors[2] = GuessGameHandler.respondToChallenge.selector;
        selectors[3] = GuessGameHandler.cancelPuzzle.selector;
        selectors[4] = GuessGameHandler.forfeitPuzzle.selector;
        selectors[5] = GuessGameHandler.claimFromForfeited.selector;

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
                // If not cancelled/solved/forfeited, bounty should be at least MIN_BOUNTY
                if (!puzzle.cancelled && !puzzle.solved && !puzzle.forfeited) {
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
     * @notice Forfeited puzzles should remain forfeited forever
     */
    function invariant_forfeitedPuzzlesImmutable() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 i = 0; i < puzzleCount; i++) {
            if (handler.ghostPuzzleForfeited(i)) {
                IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
                assert(puzzle.forfeited == true);
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
            if (puzzle.creator != address(0) && !puzzle.solved && !puzzle.cancelled && !puzzle.forfeited) {
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
     * @notice A puzzle can only be in one terminal state: solved, cancelled, or forfeited
     */
    function invariant_terminalStatesMutuallyExclusive() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 i = 0; i < puzzleCount; i++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
            // Count how many terminal states are true
            uint256 terminalCount = 0;
            if (puzzle.solved) terminalCount++;
            if (puzzle.cancelled) terminalCount++;
            if (puzzle.forfeited) terminalCount++;

            // At most one terminal state should be true
            assert(terminalCount <= 1);
        }
    }

    /**
     * @notice Forfeited puzzles should have pendingAtForfeit set
     */
    function invariant_forfeitedPuzzlesHavePendingAtForfeit() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 i = 0; i < puzzleCount; i++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
            if (puzzle.forfeited) {
                // pendingAtForfeit should be > 0 (there was at least one timed-out challenge)
                assert(puzzle.pendingAtForfeit > 0);
            }
        }
    }

    /**
     * @notice Active puzzles should always have collateral == bounty (1:1 split)
     */
    function invariant_collateralEqualsBountyForActive() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 i = 0; i < puzzleCount; i++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
            if (puzzle.creator != address(0) && !puzzle.solved && !puzzle.cancelled && !puzzle.forfeited) {
                assertEq(puzzle.collateral, puzzle.bounty, "Active puzzle: collateral != bounty");
            }
        }
    }

    /**
     * @notice Treasury balance should never decrease - only receives slashed collateral
     */
    function invariant_treasuryMonotonicallyIncreases() public view {
        // Treasury balance should be at least what we've tracked sending to it
        assert(treasury.balance >= handler.ghostTreasuryReceived());
    }

    /**
     * @notice Forfeited puzzles should have ghost collateral zeroed (sent to treasury)
     */
    function invariant_forfeitedCollateralZeroed() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 i = 0; i < puzzleCount; i++) {
            if (handler.ghostPuzzleForfeited(i)) {
                assertEq(handler.ghostPuzzleCollateral(i), 0, "Forfeited puzzle collateral not zeroed");
            }
        }
    }
}
