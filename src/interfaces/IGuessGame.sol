// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IGuessGame {
    struct Puzzle {
        address creator;
        bool solved;
        bool cancelled;
        bool forfeited;
        bytes32 commitment;
        uint256 bounty;
        uint256 stakeRequired;
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
    event PuzzleCreated(uint256 indexed puzzleId, address creator, bytes32 commitment, uint256 bounty);
    event ChallengeCreated(uint256 indexed challengeId, uint256 indexed puzzleId, address guesser, uint256 guess);
    event ChallengeResponded(uint256 indexed challengeId, bool correct);
    event PuzzleSolved(uint256 indexed puzzleId, address winner, uint256 prize);
    event PuzzleCancelled(uint256 indexed puzzleId);
    event PuzzleForfeited(uint256 indexed puzzleId);
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

    // Functions
    function createPuzzle(bytes32 commitment, uint256 stakeRequired) external payable returns (uint256 puzzleId);

    function submitGuess(uint256 puzzleId, uint256 guess) external payable returns (uint256 challengeId);

    /**
     * @notice Respond to a challenge with a ZK proof
     * @param puzzleId The puzzle the challenge belongs to
     * @param challengeId The challenge to respond to
     * @param _pA, _pB, _pC The proof components
     * @param _pubSignals Public signals: [commitment, isCorrect]
     *                    where isCorrect = 1 if guess matches secret, 0 otherwise
     * @dev The creator proves they know the secret (never revealed) and whether the guess is correct
     *      Guesser always gets their stake back
     *      If correct: puzzle is solved, guesser also wins bounty
     *      If incorrect: guesser just gets stake back
     */
    function respondToChallenge(
        uint256 puzzleId,
        uint256 challengeId,
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[3] calldata _pubSignals
    ) external;

    /**
     * @notice Cancel a puzzle and get bounty back
     * @param puzzleId The puzzle to cancel
     * @dev Only callable by creator when there are no pending challenges
     *      and CANCEL_TIMEOUT has passed since the last challenge was submitted
     */
    function cancelPuzzle(uint256 puzzleId) external;

    /**
     * @notice Forfeit a puzzle when creator hasn't responded to a challenge in time
     * @param puzzleId The puzzle to forfeit
     * @param timedOutChallengeId A challenge that has timed out (for verification)
     * @dev Callable by anyone. Requires at least one challenge to have timed out.
     *      After forfeit, all pending guessers can claim their stake + share of bounty.
     */
    function forfeitPuzzle(uint256 puzzleId, uint256 timedOutChallengeId) external;

    /**
     * @notice Claim stake and bounty share from a forfeited puzzle
     * @param puzzleId The forfeited puzzle
     * @dev Single call per guesser. Credits internal balance.
     */
    function claimFromForfeited(uint256 puzzleId) external;

    /**
     * @notice Claim stake back from a solved puzzle
     * @param puzzleId The solved puzzle
     * @dev Single call per guesser. Credits internal balance.
     */
    function claimStakeFromSolved(uint256 puzzleId) external;

    /**
     * @notice Withdraw accumulated balance
     */
    function withdraw() external;

    function CANCEL_TIMEOUT() external view returns (uint256);
    function RESPONSE_TIMEOUT() external view returns (uint256);

    function getPuzzle(uint256 puzzleId) external view returns (Puzzle memory);
    function getChallenge(uint256 puzzleId, uint256 challengeId) external view returns (Challenge memory);
    function puzzleCount() external view returns (uint256);
    function balances(address account) external view returns (uint256);
}
