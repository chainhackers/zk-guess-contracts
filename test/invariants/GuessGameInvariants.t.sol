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
        selectors[3] = GuessGameHandler.closePuzzle.selector;
        
        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
        
        // Fund handler's actors
        for (uint i = 0; i < 3; i++) {
            vm.deal(address(uint160(0x1000 + i)), 100 ether); // creators
            vm.deal(address(uint160(0x2000 + i)), 100 ether); // guessers
        }
    }
    
    /**
     * @notice Contract balance should always equal ghostTotalContractFunds
     */
    function invariant_contractBalanceMatchesTotalFunds() public view {
        uint256 contractBalance = address(game).balance;
        
        assertEq(
            contractBalance,
            handler.ghostTotalContractFunds(),
            "Contract balance doesn't match ghostTotalContractFunds"
        );
    }
    
    /**
     * @notice Puzzle and challenge IDs should only increase monotonically
     */
    function invariant_monotonicIds() public view {
        uint256 puzzleCount = game.puzzleCount();
        
        // Check each puzzle ID exists in sequence
        for (uint256 i = 0; i < puzzleCount; i++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
            // If puzzle was deleted, creator should be address(0)
            // Otherwise, it should have valid data
            if (puzzle.creator != address(0)) {
                assert(puzzle.bounty >= 0.001 ether);
            }

            // Check each challenge ID exists in sequence
            uint256 challengeCount = handler.ghostPuzzleChallengeCount(i);
            for (uint256 challengeId = 0; challengeId < challengeCount; challengeId++) {
                IGuessGame.Challenge memory challenge = game.getChallenge(i, challengeId);
                // All challenges should have a guesser (never deleted)
                assert(challenge.guesser != address(0));
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
     * @notice Challenge responses should be immutable
     */
    function invariant_challengeResponsesImmutable() public view {
        uint256 puzzleCount = game.puzzleCount();

        for (uint256 puzzleId = 0; puzzleId < puzzleCount; puzzleId++) {
            uint256 challengeCount = handler.ghostPuzzleChallengeCount(puzzleId);

            for (uint256 challengeId = 0; challengeId < challengeCount; challengeId++) {
                if (handler.ghostChallengeResponded(puzzleId, challengeId)) {
                    IGuessGame.Challenge memory challenge = game.getChallenge(puzzleId, challengeId);
                    assert(challenge.responded == true);
                }
            }
        }
    }
    
    /**
     * @notice Growth percent should always be <= 100
     */
    function invariant_growthPercentBounds() public view {
        uint256 puzzleCount = game.puzzleCount();
        
        for (uint256 i = 0; i < puzzleCount; i++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
            if (puzzle.creator != address(0)) {
                assert(puzzle.bountyGrowthPercent <= 100);
            }
        }
    }
    
    /**
     * @notice All puzzles should have minimum bounty if they exist
     */
    function invariant_minimumBounty() public view {
        uint256 puzzleCount = game.puzzleCount();
        
        for (uint256 i = 0; i < puzzleCount; i++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
            if (puzzle.creator != address(0)) {
                assert(puzzle.bounty >= 0.001 ether);
            }
        }
    }
    
    /**
     * @notice Creator rewards accounting should be consistent
     */
    function invariant_creatorRewardAccounting() public view {
        uint256 puzzleCount = game.puzzleCount();
        
        for (uint256 puzzleId = 0; puzzleId < puzzleCount; puzzleId++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
            if (puzzle.creator == address(0) || puzzle.solved) continue;
            
            // Calculate expected creator reward from incorrect guesses
            uint256 expectedCreatorReward = 0;
            uint256 challengeCount = handler.ghostPuzzleChallengeCount(puzzleId);
            
            for (uint256 challengeId = 0; challengeId < challengeCount; challengeId++) {
                IGuessGame.Challenge memory challenge = game.getChallenge(puzzleId, challengeId);
                if (challenge.responded) {
                    // This was an incorrect guess
                    uint256 stakeGrowth = (challenge.stake * puzzle.bountyGrowthPercent) / 100;
                    expectedCreatorReward += (challenge.stake - stakeGrowth);
                }
            }

            assertEq(puzzle.creatorReward, expectedCreatorReward);
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
}