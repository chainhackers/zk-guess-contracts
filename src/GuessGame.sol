// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./interfaces/IGroth16Verifier.sol";
import "./interfaces/IGuessGame.sol";

contract GuessGame is IGuessGame {
    IGroth16Verifier public immutable verifier;
    uint256 public puzzleCount;
    uint256 public challengeCount;
    
    mapping(uint256 => Puzzle) public puzzles;
    mapping(uint256 => Challenge) public challenges;
    mapping(uint256 => uint256) public challengeToPuzzle;
    
    uint256 constant MIN_BOUNTY = 0.001 ether;
    
    constructor(address _verifier) {
        if (_verifier == address(0)) revert InvalidVerifierAddress();
        verifier = IGroth16Verifier(_verifier);
    }
    
    function createPuzzle(
        bytes32 commitment,
        uint256 stakeRequired,
        uint8 bountyGrowthPercent
    ) external payable returns (uint256 puzzleId) {
        if (msg.value < MIN_BOUNTY) revert InsufficientBounty();
        if (bountyGrowthPercent > 100) revert InvalidGrowthPercent();
        
        puzzleId = puzzleCount++;
        puzzles[puzzleId] = Puzzle({
            creator: msg.sender,
            commitment: commitment,
            bounty: msg.value,
            stakeRequired: stakeRequired,
            bountyGrowthPercent: bountyGrowthPercent,
            totalStaked: 0,
            creatorReward: 0,
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
        if (msg.sender == puzzle.creator) revert CannotGuessOwnPuzzle();
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
        
        // Verify the proof using external verifier
        if (!verifier.verifyProof(_pA, _pB, _pC, _pubSignals)) revert InvalidProof();
        
        // Extract public signals
        bytes32 commitment = bytes32(_pubSignals[0]);
        bool isCorrect = _pubSignals[1] == 1;
        
        // Verify commitment matches puzzle
        if (commitment != puzzle.commitment) revert InvalidProof();
        
        challenge.responded = true;
        emit ChallengeResponded(challengeId, isCorrect);
        
        if (isCorrect) {
            puzzle.solved = true;
            
            uint256 totalPrize = puzzle.bounty + puzzle.totalStaked - puzzle.creatorReward;
            emit PuzzleSolved(puzzleId, challenge.guesser, totalPrize);
            
            (bool success, ) = challenge.guesser.call{value: totalPrize}("");
            if (!success) revert TransferToWinnerFailed();
        } else {
            uint256 stakeGrowth = (challenge.stake * puzzle.bountyGrowthPercent) / 100;
            puzzle.bounty += stakeGrowth;
            puzzle.creatorReward += (challenge.stake - stakeGrowth);
        }
    }
    
    function getPuzzle(uint256 puzzleId) external view returns (Puzzle memory) {
        return puzzles[puzzleId];
    }
    
    function getChallenge(uint256 challengeId) external view returns (Challenge memory) {
        return challenges[challengeId];
    }
    
    function closePuzzle(uint256 puzzleId) external {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (msg.sender != puzzle.creator) revert OnlyPuzzleCreator();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        
        uint256 totalAmount = puzzle.bounty + puzzle.totalStaked;
        if (totalAmount == 0) revert NothingToClaim();
        
        // Delete puzzle to get gas refund
        delete puzzles[puzzleId];
        
        (bool success, ) = msg.sender.call{value: totalAmount}("");
        if (!success) revert TransferToClaimerFailed();
    }
}