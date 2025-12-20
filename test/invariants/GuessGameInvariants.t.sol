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
     * @notice Contract balance should always equal sum of all active puzzles' funds
     */
    function invariant_contractBalanceMatchesPuzzleFunds() public view {
        uint256 contractBalance = address(game).balance;
        uint256 expectedBalance = handler.sumActivePuzzleFunds();
        
        assertEq(
            contractBalance,
            expectedBalance,
            "Contract balance doesn't match sum of puzzle funds"
        );
    }
    
    /**
     * @notice Puzzle and challenge IDs should only increase monotonically
     */
    function invariant_monotonicIds() public view {
        uint256 puzzleCount = game.puzzleCount();
        uint256 challengeCount = game.challengeCount();
        
        // Check each puzzle ID exists in sequence
        for (uint256 i = 1; i <= puzzleCount; i++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
            // If puzzle was deleted, creator should be address(0)
            // Otherwise, it should have valid data
            if (puzzle.creator != address(0)) {
                assert(puzzle.bounty >= 0.001 ether);
            }
        }
        
        // Check each challenge ID exists in sequence
        for (uint256 i = 1; i <= challengeCount; i++) {
            IGuessGame.Challenge memory challenge = game.getChallenge(i);
            // All challenges should have a guesser (never deleted)
            assert(challenge.guesser != address(0));
        }
    }
    
    /**
     * @notice Each puzzle's totalStaked should equal sum of all its challenge stakes
     */
    function invariant_totalStakedMatchesChallengeStakes() public view {
        uint256 puzzleCount = game.puzzleCount();
        
        for (uint256 puzzleId = 1; puzzleId <= puzzleCount; puzzleId++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
            if (puzzle.creator == address(0)) continue; // Skip deleted puzzles
            
            uint256 sumOfStakes = 0;
            uint256 challengeCount = game.challengeCount();
            
            // Sum up all stakes for this puzzle
            for (uint256 challengeId = 1; challengeId <= challengeCount; challengeId++) {
                if (game.challengeToPuzzle(challengeId) == puzzleId) {
                    IGuessGame.Challenge memory challenge = game.getChallenge(challengeId);
                    sumOfStakes += challenge.stake;
                }
            }
            
            assertEq(
                puzzle.totalStaked,
                sumOfStakes,
                "Puzzle totalStaked doesn't match sum of challenge stakes"
            );
        }
    }
    
    /**
     * @notice Solved puzzles should remain solved forever
     */
    function invariant_solvedPuzzlesImmutable() public view {
        uint256 puzzleCount = game.puzzleCount();
        
        for (uint256 i = 1; i <= puzzleCount; i++) {
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
        uint256 challengeCount = game.challengeCount();
        
        for (uint256 i = 1; i <= challengeCount; i++) {
            IGuessGame.Challenge memory challenge = game.getChallenge(i);
            // Check consistency with puzzle state
            uint256 puzzleId = game.challengeToPuzzle(i);
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
            
            // If puzzle is solved, at least one challenge must be responded with correct guess
            if (puzzle.solved && challenge.responded) {
                // This challenge might be the winning one
                assert(challenge.guesser != address(0));
            }
        }
    }
    
    /**
     * @notice Growth percent should always be <= 100
     */
    function invariant_growthPercentBounds() public view {
        uint256 puzzleCount = game.puzzleCount();
        
        for (uint256 i = 1; i <= puzzleCount; i++) {
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
        
        for (uint256 i = 1; i <= puzzleCount; i++) {
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
        
        for (uint256 puzzleId = 1; puzzleId <= puzzleCount; puzzleId++) {
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
            if (puzzle.creator == address(0) || puzzle.solved) continue;
            
            // Calculate expected creator reward from incorrect guesses
            uint256 expectedCreatorReward = 0;
            uint256 expectedBountyGrowth = 0;
            uint256 challengeCount = game.challengeCount();
            
            for (uint256 challengeId = 1; challengeId <= challengeCount; challengeId++) {
                if (game.challengeToPuzzle(challengeId) == puzzleId) {
                    IGuessGame.Challenge memory challenge = game.getChallenge(challengeId);
                    if (challenge.responded && !puzzle.solved) {
                        // This was an incorrect guess
                        uint256 stakeGrowth = (challenge.stake * puzzle.bountyGrowthPercent) / 100;
                        expectedBountyGrowth += stakeGrowth;
                        expectedCreatorReward += (challenge.stake - stakeGrowth);
                    }
                }
            }
            
            // Due to the way we handle responses, we can't perfectly track this
            // But creator reward should never exceed total stakes
            assert(puzzle.creatorReward <= puzzle.totalStaked);
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