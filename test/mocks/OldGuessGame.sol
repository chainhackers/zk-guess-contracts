// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./IGroth16VerifierV1.sol";

/// @title OldGuessGame
/// @notice Old version of GuessGame from commit e6bc579 for upgrade testing
/// @dev Key differences from new version:
///      - MIN_BOUNTY = 0.001 ether (vs 0.0001 ether)
///      - createPuzzle requires msg.value >= MIN_BOUNTY * 2
///      - collateral = msg.value / 2, bounty = msg.value - collateral
///      - No lastResponseTime field in Puzzle struct
///      - Forfeit uses challenge.timestamp directly
contract OldGuessGame is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    /// @notice Old Puzzle struct without lastResponseTime field
    struct OldPuzzle {
        address creator;
        bool solved;
        bool cancelled;
        bool forfeited;
        bytes32 commitment;
        uint256 bounty;
        uint256 collateral;
        uint256 stakeRequired;
        uint256 maxNumber;
        uint256 challengeCount;
        uint256 pendingChallenges;
        uint256 lastChallengeTimestamp;
        uint256 pendingAtForfeit;
    }

    struct Challenge {
        address guesser;
        bool responded;
        uint256 guess;
        uint256 stake;
        uint256 timestamp;
    }

    // Events
    event PuzzleCreated(
        uint256 indexed puzzleId, address creator, bytes32 commitment, uint256 bounty, uint256 maxNumber
    );
    event ChallengeCreated(uint256 indexed challengeId, uint256 indexed puzzleId, address guesser, uint256 guess);
    event ChallengeResponded(uint256 indexed challengeId, bool correct);
    event PuzzleSolved(uint256 indexed puzzleId, address winner, uint256 prize);
    event PuzzleCancelled(uint256 indexed puzzleId);
    event PuzzleForfeited(uint256 indexed puzzleId);
    event CollateralSlashed(uint256 indexed puzzleId, uint256 amount);
    event ForfeitClaimed(uint256 indexed puzzleId, address guesser, uint256 amount);
    event StakeClaimedFromSolved(uint256 indexed puzzleId, address guesser, uint256 stake);
    event Withdrawal(address indexed account, uint256 amount);

    // Errors
    error InsufficientBounty();
    error InsufficientStake();
    error PuzzleAlreadySolved();
    error PuzzleCancelledError();
    error PuzzleForfeitedError();
    error ChallengeAlreadyResponded();
    error OnlyPuzzleCreator();
    error InvalidProof();
    error InvalidProofForChallengeGuess();
    error ChallengeNotFound();
    error PuzzleNotFound();
    error InvalidVerifierAddress();
    error InvalidOwnerAddress();
    error NothingToClaim();
    error HasPendingChallenges();
    error CancelTooSoon();
    error TransferFailed();
    error NoTimedOutChallenge();
    error NotYourChallenge();
    error PuzzleNotForfeited();
    error PuzzleNotSolved();
    error CreatorCannotGuess();
    error AlreadyClaimed();
    error NothingToWithdraw();
    error GuessAlreadySubmitted();
    error InvalidGuessRange();
    error InvalidMaxNumber();

    IGroth16VerifierV1 public verifier;
    address public treasury;
    uint256 public puzzleCount;

    mapping(uint256 => OldPuzzle) public puzzles;
    mapping(uint256 => mapping(uint256 => Challenge)) public puzzleChallenges;
    mapping(uint256 => mapping(uint256 => bool)) public guessSubmitted;

    mapping(uint256 => mapping(address => uint256)) public guesserStakeTotal;
    mapping(uint256 => mapping(address => uint256)) public guesserChallengeCount;
    mapping(uint256 => mapping(address => bool)) public guesserClaimed;

    mapping(address => uint256) public balances;

    // OLD: MIN_BOUNTY was 0.001 ether (not 0.0001)
    uint256 constant MIN_BOUNTY = 0.001 ether;
    uint256 constant MIN_STAKE = 0.00001 ether;
    uint256 public constant CANCEL_TIMEOUT = 1 days;
    uint256 public constant RESPONSE_TIMEOUT = 1 days;

    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _verifier, address _treasury, address _owner) public initializer {
        if (_owner == address(0)) revert InvalidOwnerAddress();
        __Ownable_init(_owner);

        if (_verifier == address(0)) revert InvalidVerifierAddress();
        verifier = IGroth16VerifierV1(_verifier);
        treasury = _treasury;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice OLD createPuzzle logic: requires msg.value >= MIN_BOUNTY * 2
    function createPuzzle(bytes32 commitment, uint256 stakeRequired, uint256 maxNumber)
        external
        payable
        returns (uint256 puzzleId)
    {
        // OLD: msg.value must be at least 2x MIN_BOUNTY (bounty + collateral)
        if (msg.value < MIN_BOUNTY * 2) revert InsufficientBounty();
        if (stakeRequired < MIN_STAKE) revert InsufficientStake();
        if (maxNumber == 0 || maxNumber > 65535) revert InvalidMaxNumber();

        // OLD: Floor division - collateral = msg.value / 2, bounty = rest
        uint256 collateral = msg.value / 2;
        uint256 bounty = msg.value - collateral;

        puzzleId = puzzleCount++;
        puzzles[puzzleId] = OldPuzzle({
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
        OldPuzzle storage puzzle = puzzles[puzzleId];
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
        OldPuzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (msg.sender != puzzle.creator) revert OnlyPuzzleCreator();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();

        Challenge storage challenge = puzzleChallenges[puzzleId][challengeId];
        if (challenge.guesser == address(0)) revert ChallengeNotFound();
        if (challenge.responded) revert ChallengeAlreadyResponded();

        if (!verifier.verifyProof(_pA, _pB, _pC, _pubSignals)) revert InvalidProof();

        bytes32 commitment = bytes32(_pubSignals[0]);
        bool isCorrect = _pubSignals[1] == 1;
        uint256 proofGuess = _pubSignals[2];
        uint256 proofMaxNumber = _pubSignals[3];

        if (commitment != puzzle.commitment) revert InvalidProof();
        if (proofGuess != challenge.guess) revert InvalidProofForChallengeGuess();
        if (proofMaxNumber != puzzle.maxNumber) revert InvalidProof();

        challenge.responded = true;
        puzzle.pendingChallenges--;

        guesserStakeTotal[puzzleId][challenge.guesser] -= challenge.stake;
        guesserChallengeCount[puzzleId][challenge.guesser]--;

        emit ChallengeResponded(challengeId, isCorrect);

        if (isCorrect) {
            puzzle.solved = true;

            uint256 totalPrize = puzzle.bounty + challenge.stake;
            emit PuzzleSolved(puzzleId, challenge.guesser, totalPrize);

            balances[puzzle.creator] += puzzle.collateral;

            (bool success,) = challenge.guesser.call{value: totalPrize}("");
            if (!success) revert TransferFailed();
        } else {
            (bool success,) = challenge.guesser.call{value: challenge.stake}("");
            if (!success) revert TransferFailed();
        }
    }

    function cancelPuzzle(uint256 puzzleId) external {
        OldPuzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (msg.sender != puzzle.creator) revert OnlyPuzzleCreator();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();
        if (puzzle.pendingChallenges > 0) revert HasPendingChallenges();
        if (puzzle.lastChallengeTimestamp != 0 && block.timestamp < puzzle.lastChallengeTimestamp + CANCEL_TIMEOUT) {
            revert CancelTooSoon();
        }

        puzzle.cancelled = true;

        emit PuzzleCancelled(puzzleId);

        (bool success,) = puzzle.creator.call{value: puzzle.bounty + puzzle.collateral}("");
        if (!success) revert TransferFailed();
    }

    /// @notice OLD forfeit logic: uses challenge.timestamp directly (no rolling deadline)
    function forfeitPuzzle(uint256 puzzleId, uint256 timedOutChallengeId) external {
        OldPuzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();

        Challenge storage challenge = puzzleChallenges[puzzleId][timedOutChallengeId];
        if (challenge.guesser == address(0)) revert ChallengeNotFound();
        if (challenge.responded) revert ChallengeAlreadyResponded();
        // OLD: Uses challenge.timestamp directly, not rolling deadline
        if (block.timestamp < challenge.timestamp + RESPONSE_TIMEOUT) revert NoTimedOutChallenge();

        puzzle.forfeited = true;
        puzzle.pendingAtForfeit = puzzle.pendingChallenges;

        emit PuzzleForfeited(puzzleId);

        if (puzzle.collateral > 0) {
            emit CollateralSlashed(puzzleId, puzzle.collateral);
            (bool success,) = treasury.call{value: puzzle.collateral}("");
            if (!success) revert TransferFailed();
        }
    }

    function claimFromForfeited(uint256 puzzleId) external {
        OldPuzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (!puzzle.forfeited) revert PuzzleNotForfeited();
        if (guesserClaimed[puzzleId][msg.sender]) revert AlreadyClaimed();

        uint256 myChallenges = guesserChallengeCount[puzzleId][msg.sender];
        uint256 myStake = guesserStakeTotal[puzzleId][msg.sender];
        if (myChallenges == 0) revert NothingToClaim();

        guesserClaimed[puzzleId][msg.sender] = true;

        uint256 bountyShare = (puzzle.bounty * myChallenges) / puzzle.pendingAtForfeit;
        uint256 totalPayout = myStake + bountyShare;

        balances[msg.sender] += totalPayout;

        emit ForfeitClaimed(puzzleId, msg.sender, totalPayout);
    }

    function claimStakeFromSolved(uint256 puzzleId) external {
        OldPuzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (!puzzle.solved) revert PuzzleNotSolved();
        if (guesserClaimed[puzzleId][msg.sender]) revert AlreadyClaimed();

        uint256 myStake = guesserStakeTotal[puzzleId][msg.sender];
        if (myStake == 0) revert NothingToClaim();

        guesserClaimed[puzzleId][msg.sender] = true;

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

    function getPuzzle(uint256 puzzleId) external view returns (OldPuzzle memory) {
        return puzzles[puzzleId];
    }

    function getChallenge(uint256 puzzleId, uint256 challengeId) external view returns (Challenge memory) {
        return puzzleChallenges[puzzleId][challengeId];
    }
}
