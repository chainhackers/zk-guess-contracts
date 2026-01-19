// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./interfaces/IGroth16Verifier.sol";
import "./interfaces/IGuessGame.sol";

contract GuessGame is IGuessGame {
    IGroth16Verifier public immutable verifier;
    uint256 public puzzleCount;

    mapping(uint256 => Puzzle) public puzzles;
    mapping(uint256 => mapping(uint256 => Challenge)) public puzzleChallenges;

    uint256 constant MIN_BOUNTY = 0.001 ether;
    uint256 public constant CANCEL_TIMEOUT = 1 days;
    uint256 public constant RESPONSE_TIMEOUT = 1 days;

    constructor(address _verifier) {
        if (_verifier == address(0)) revert InvalidVerifierAddress();
        verifier = IGroth16Verifier(_verifier);
    }

    function createPuzzle(
        bytes32 commitment,
        uint256 stakeRequired
    ) external payable returns (uint256 puzzleId) {
        if (msg.value < MIN_BOUNTY) revert InsufficientBounty();

        puzzleId = puzzleCount++;
        puzzles[puzzleId] = Puzzle({
            creator: msg.sender,
            solved: false,
            cancelled: false,
            forfeited: false,
            commitment: commitment,
            bounty: msg.value,
            stakeRequired: stakeRequired,
            challengeCount: 0,
            pendingChallenges: 0,
            lastChallengeTimestamp: 0,
            pendingAtForfeit: 0
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
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();
        if (msg.value < puzzle.stakeRequired) revert InsufficientStake();

        challengeId = puzzle.challengeCount++;
        puzzle.pendingChallenges++;
        puzzle.lastChallengeTimestamp = block.timestamp;

        puzzleChallenges[puzzleId][challengeId] = Challenge({
            guesser: msg.sender,
            responded: false,
            guess: guess,
            stake: msg.value,
            timestamp: block.timestamp
        });

        emit ChallengeCreated(challengeId, puzzleId, msg.sender, guess);
    }

    function respondToChallenge(
        uint256 puzzleId,
        uint256 challengeId,
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[3] calldata _pubSignals
    ) external {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (msg.sender != puzzle.creator) revert OnlyPuzzleCreator();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();

        Challenge storage challenge = puzzleChallenges[puzzleId][challengeId];
        if (challenge.guesser == address(0)) revert ChallengeNotFound();
        if (challenge.responded) revert ChallengeAlreadyResponded();

        // Verify the proof using external verifier
        if (!verifier.verifyProof(_pA, _pB, _pC, _pubSignals)) revert InvalidProof();

        // Extract public signals
        bytes32 commitment = bytes32(_pubSignals[0]);
        bool isCorrect = _pubSignals[1] == 1;
        uint256 proofGuess = _pubSignals[2];

        // Verify commitment matches puzzle
        if (commitment != puzzle.commitment) revert InvalidProof();
        if (proofGuess != challenge.guess) revert InvalidProofForChallengeGuess();

        challenge.responded = true;
        puzzle.pendingChallenges--;

        emit ChallengeResponded(challengeId, isCorrect);

        if (isCorrect) {
            puzzle.solved = true;

            // Winner gets bounty + their stake back
            uint256 totalPrize = puzzle.bounty + challenge.stake;
            emit PuzzleSolved(puzzleId, challenge.guesser, totalPrize);

            (bool success,) = challenge.guesser.call{value: totalPrize}("");
            if (!success) revert TransferFailed();
        } else {
            // Wrong guess: guesser gets stake back
            (bool success,) = challenge.guesser.call{value: challenge.stake}("");
            if (!success) revert TransferFailed();
        }
    }

    function cancelPuzzle(uint256 puzzleId) external {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (msg.sender != puzzle.creator) revert OnlyPuzzleCreator();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();
        if (puzzle.pendingChallenges > 0) revert HasPendingChallenges();
        // Can only cancel if no challenges yet, or timeout has passed since last challenge
        if (puzzle.lastChallengeTimestamp != 0 && block.timestamp < puzzle.lastChallengeTimestamp + CANCEL_TIMEOUT) {
            revert CancelTooSoon();
        }

        puzzle.cancelled = true;

        emit PuzzleCancelled(puzzleId);

        // Return bounty to creator
        (bool success,) = puzzle.creator.call{value: puzzle.bounty}("");
        if (!success) revert TransferFailed();
    }

    function forfeitPuzzle(uint256 puzzleId, uint256 timedOutChallengeId) external {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();

        // Verify the provided challenge has timed out
        Challenge storage challenge = puzzleChallenges[puzzleId][timedOutChallengeId];
        if (challenge.guesser == address(0)) revert ChallengeNotFound();
        if (challenge.responded) revert ChallengeAlreadyResponded();
        if (block.timestamp < challenge.timestamp + RESPONSE_TIMEOUT) revert NoTimedOutChallenge();

        // Mark puzzle as forfeited
        puzzle.forfeited = true;
        puzzle.pendingAtForfeit = puzzle.pendingChallenges;

        emit PuzzleForfeited(puzzleId);
    }

    function claimFromForfeited(uint256 puzzleId, uint256 challengeId) external {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (!puzzle.forfeited) revert PuzzleNotForfeited();

        Challenge storage challenge = puzzleChallenges[puzzleId][challengeId];
        if (challenge.guesser == address(0)) revert ChallengeNotFound();
        if (msg.sender != challenge.guesser) revert NotYourChallenge();
        if (challenge.responded) revert ChallengeAlreadyResponded();

        // Mark as responded to prevent double claim
        challenge.responded = true;
        puzzle.pendingChallenges--;

        // Calculate payout: stake + proportional share of bounty
        uint256 bountyShare = puzzle.bounty / puzzle.pendingAtForfeit;
        uint256 totalPayout = challenge.stake + bountyShare;

        emit ForfeitClaimed(puzzleId, challengeId, msg.sender, totalPayout);

        (bool success,) = msg.sender.call{value: totalPayout}("");
        if (!success) revert TransferFailed();
    }

    function getPuzzle(uint256 puzzleId) external view returns (Puzzle memory) {
        return puzzles[puzzleId];
    }

    function getChallenge(uint256 puzzleId, uint256 challengeId) external view returns (Challenge memory) {
        return puzzleChallenges[puzzleId][challengeId];
    }
}
