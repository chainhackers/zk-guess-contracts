// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./interfaces/IGroth16Verifier.sol";
import "./interfaces/IGuessGame.sol";

contract GuessGame is IGuessGame {
    IGroth16Verifier public immutable verifier;
    address public immutable treasury;
    uint256 public puzzleCount;

    mapping(uint256 => Puzzle) public puzzles;
    mapping(uint256 => mapping(uint256 => Challenge)) public puzzleChallenges;
    mapping(uint256 => mapping(uint256 => bool)) public guessSubmitted;

    // Per-guesser aggregates per puzzle
    mapping(uint256 => mapping(address => uint256)) public guesserStakeTotal;
    mapping(uint256 => mapping(address => uint256)) public guesserChallengeCount;
    mapping(uint256 => mapping(address => bool)) public guesserClaimed;

    // Internal balances for withdrawal
    mapping(address => uint256) public balances;

    uint256 constant MIN_BOUNTY = 0.001 ether;
    uint256 constant MIN_STAKE = 0.00001 ether;
    uint256 public constant CANCEL_TIMEOUT = 1 days;
    uint256 public constant RESPONSE_TIMEOUT = 1 days;

    constructor(address _verifier, address _treasury) {
        if (_verifier == address(0)) revert InvalidVerifierAddress();
        verifier = IGroth16Verifier(_verifier);
        treasury = _treasury;
    }

    function createPuzzle(bytes32 commitment, uint256 stakeRequired, uint256 maxNumber)
        external
        payable
        returns (uint256 puzzleId)
    {
        // msg.value must be at least 2x MIN_BOUNTY (bounty + collateral)
        if (msg.value < MIN_BOUNTY * 2) revert InsufficientBounty();
        if (stakeRequired < MIN_STAKE) revert InsufficientStake();
        if (maxNumber == 0 || maxNumber > 65535) revert InvalidMaxNumber();

        // Floor division: extra wei goes to bounty
        uint256 collateral = msg.value / 2;
        uint256 bounty = msg.value - collateral;

        puzzleId = puzzleCount++;
        puzzles[puzzleId] = Puzzle({
            creator: msg.sender,
            solved: false,
            cancelled: false,
            forfeited: false,
            commitment: commitment,
            bounty: bounty,
            collateral: collateral,
            stakeRequired: stakeRequired,
            maxNumber: maxNumber,
            challengeCount: 0,
            pendingChallenges: 0,
            lastChallengeTimestamp: 0,
            pendingAtForfeit: 0
        });

        emit PuzzleCreated(puzzleId, msg.sender, commitment, bounty, maxNumber);
    }

    function submitGuess(uint256 puzzleId, uint256 guess) external payable returns (uint256 challengeId) {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();
        if (msg.sender == puzzle.creator) revert CreatorCannotGuess();
        if (msg.value < puzzle.stakeRequired) revert InsufficientStake();
        if (guess == 0 || guess > puzzle.maxNumber) revert InvalidGuessRange();
        if (guessSubmitted[puzzleId][guess]) revert GuessAlreadySubmitted();

        guessSubmitted[puzzleId][guess] = true;

        challengeId = puzzle.challengeCount++;
        puzzle.pendingChallenges++;
        puzzle.lastChallengeTimestamp = block.timestamp;

        // Track per-guesser aggregates
        guesserStakeTotal[puzzleId][msg.sender] += msg.value;
        guesserChallengeCount[puzzleId][msg.sender]++;

        puzzleChallenges[puzzleId][challengeId] = Challenge({
            guesser: msg.sender, responded: false, guess: guess, stake: msg.value, timestamp: block.timestamp
        });

        emit ChallengeCreated(challengeId, puzzleId, msg.sender, guess);
    }

    function respondToChallenge(
        uint256 puzzleId,
        uint256 challengeId,
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[4] calldata _pubSignals
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

        // Extract public signals: [commitment, isCorrect, guess, maxNumber]
        bytes32 commitment = bytes32(_pubSignals[0]);
        bool isCorrect = _pubSignals[1] == 1;
        uint256 proofGuess = _pubSignals[2];
        uint256 proofMaxNumber = _pubSignals[3];

        // Verify proof matches puzzle parameters
        if (commitment != puzzle.commitment) revert InvalidProof();
        if (proofGuess != challenge.guess) revert InvalidProofForChallengeGuess();
        if (proofMaxNumber != puzzle.maxNumber) revert InvalidProof();

        challenge.responded = true;
        puzzle.pendingChallenges--;

        // Decrement guesser aggregates
        guesserStakeTotal[puzzleId][challenge.guesser] -= challenge.stake;
        guesserChallengeCount[puzzleId][challenge.guesser]--;

        emit ChallengeResponded(challengeId, isCorrect);

        if (isCorrect) {
            puzzle.solved = true;

            // Winner gets bounty + their stake back
            uint256 totalPrize = puzzle.bounty + challenge.stake;
            emit PuzzleSolved(puzzleId, challenge.guesser, totalPrize);

            // Return collateral to creator
            balances[puzzle.creator] += puzzle.collateral;

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

        // Return bounty + collateral to creator
        (bool success,) = puzzle.creator.call{value: puzzle.bounty + puzzle.collateral}("");
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

        // Slash collateral to treasury
        if (puzzle.collateral > 0) {
            emit CollateralSlashed(puzzleId, puzzle.collateral);
            (bool success,) = treasury.call{value: puzzle.collateral}("");
            if (!success) revert TransferFailed();
        }
    }

    function claimFromForfeited(uint256 puzzleId) external {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (!puzzle.forfeited) revert PuzzleNotForfeited();
        if (guesserClaimed[puzzleId][msg.sender]) revert AlreadyClaimed();

        uint256 myChallenges = guesserChallengeCount[puzzleId][msg.sender];
        uint256 myStake = guesserStakeTotal[puzzleId][msg.sender];
        if (myChallenges == 0) revert NothingToClaim();

        // Mark as claimed
        guesserClaimed[puzzleId][msg.sender] = true;

        // Calculate payout: stake + proportional share of bounty
        uint256 bountyShare = (puzzle.bounty * myChallenges) / puzzle.pendingAtForfeit;
        uint256 totalPayout = myStake + bountyShare;

        // Credit to internal balance
        balances[msg.sender] += totalPayout;

        emit ForfeitClaimed(puzzleId, msg.sender, totalPayout);
    }

    function claimStakeFromSolved(uint256 puzzleId) external {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (!puzzle.solved) revert PuzzleNotSolved();
        if (guesserClaimed[puzzleId][msg.sender]) revert AlreadyClaimed();

        uint256 myStake = guesserStakeTotal[puzzleId][msg.sender];
        if (myStake == 0) revert NothingToClaim();

        // Mark as claimed
        guesserClaimed[puzzleId][msg.sender] = true;

        // Credit stake to internal balance
        balances[msg.sender] += myStake;

        emit StakeClaimedFromSolved(puzzleId, msg.sender, myStake);
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        balances[msg.sender] = 0;

        emit Withdrawal(msg.sender, amount);

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function getPuzzle(uint256 puzzleId) external view returns (Puzzle memory) {
        return puzzles[puzzleId];
    }

    function getChallenge(uint256 puzzleId, uint256 challengeId) external view returns (Challenge memory) {
        return puzzleChallenges[puzzleId][challengeId];
    }
}
