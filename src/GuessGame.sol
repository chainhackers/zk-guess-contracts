// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./GuessVerifier.sol";
import "./interfaces/IGuessGame.sol";

contract GuessGame is Groth16Verifier, IGuessGame {
    uint256 public puzzleCount;
    uint256 public challengeCount;
    
    mapping(uint256 => Puzzle) public puzzles;
    mapping(uint256 => Challenge) public challenges;
    mapping(uint256 => uint256) public challengeToPuzzle;
    
    uint256 constant MIN_BOUNTY = 0.001 ether;
    
    function createPuzzle(
        bytes32 commitment,
        uint256 stakeRequired,
        uint8 bountyGrowthPercent
    ) external payable returns (uint256 puzzleId) {
        if (msg.value < MIN_BOUNTY) revert InsufficientBounty();
        if (bountyGrowthPercent > 100) revert("Invalid growth percent");
        
        puzzleId = puzzleCount++;
        puzzles[puzzleId] = Puzzle({
            creator: msg.sender,
            commitment: commitment,
            bounty: msg.value,
            stakeRequired: stakeRequired,
            bountyGrowthPercent: bountyGrowthPercent,
            totalStaked: 0,
            solved: false
        });
        
        emit PuzzleCreated(puzzleId, msg.sender, commitment, msg.value);
    }
    
    function submitGuess(
        uint256 puzzleId,
        uint256 guess
    ) external payable returns (uint256 challengeId) {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (msg.value < puzzle.stakeRequired) revert InsufficientStake();
        
        challengeId = challengeCount++;
        challenges[challengeId] = Challenge({
            guesser: msg.sender,
            guess: guess,
            stake: msg.value,
            timestamp: block.timestamp,
            responded: false
        });
        challengeToPuzzle[challengeId] = puzzleId;
        
        puzzle.totalStaked += msg.value;
        
        emit ChallengeCreated(challengeId, puzzleId, msg.sender, guess);
    }
    
    function respondToChallenge(
        uint256 challengeId,
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[2] calldata _pubSignals
    ) external {
        Challenge storage challenge = challenges[challengeId];
        if (challenge.guesser == address(0)) revert ChallengeNotFound();
        if (challenge.responded) revert ChallengeAlreadyResponded();
        
        uint256 puzzleId = challengeToPuzzle[challengeId];
        Puzzle storage puzzle = puzzles[puzzleId];
        if (msg.sender != puzzle.creator) revert OnlyPuzzleCreator();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        
        // Verify the proof
        if (!verifyProof(_pA, _pB, _pC, _pubSignals)) revert InvalidProof();
        
        // Extract public signals
        bytes32 commitment = bytes32(_pubSignals[0]);
        bool isCorrect = _pubSignals[1] == 1;
        
        // Verify commitment matches puzzle
        if (commitment != puzzle.commitment) revert InvalidProof();
        
        challenge.responded = true;
        emit ChallengeResponded(challengeId, isCorrect);
        
        if (isCorrect) {
            // Puzzle solved! Winner gets bounty + all stakes
            puzzle.solved = true;
            uint256 totalPrize = puzzle.bounty + puzzle.totalStaked;
            
            emit PuzzleSolved(puzzleId, challenge.guesser, totalPrize);
            
            // Transfer prize to winner
            (bool success, ) = challenge.guesser.call{value: totalPrize}("");
            require(success, "Transfer failed");
        } else {
            // Wrong guess - add stake to bounty
            uint256 stakeGrowth = (challenge.stake * puzzle.bountyGrowthPercent) / 100;
            puzzle.bounty += stakeGrowth;
            
            // Return remaining stake to creator
            uint256 creatorShare = challenge.stake - stakeGrowth;
            if (creatorShare > 0) {
                (bool success, ) = puzzle.creator.call{value: creatorShare}("");
                require(success, "Transfer failed");
            }
        }
    }
    
    function getPuzzle(uint256 puzzleId) external view returns (Puzzle memory) {
        return puzzles[puzzleId];
    }
    
    function getChallenge(uint256 challengeId) external view returns (Challenge memory) {
        return challenges[challengeId];
    }
}