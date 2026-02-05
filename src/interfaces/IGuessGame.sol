// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IGuessGame
/// @notice Interface for the ZK-based number guessing game with on-chain Groth16 verification
/// @dev Puzzle creators commit to a secret number, guessers submit challenges, creators respond with ZK proofs
interface IGuessGame {
    /// @notice Represents a puzzle created by a user
    /// @dev Puzzles transition through states: active -> solved/cancelled/forfeited
    struct Puzzle {
        /// @notice Address that created the puzzle and must respond to challenges
        address creator;
        /// @notice True if a guesser correctly guessed the secret number
        bool solved;
        /// @notice True if creator cancelled the puzzle (only when no pending challenges)
        bool cancelled;
        /// @notice True if creator failed to respond within timeout and puzzle was forfeited
        bool forfeited;
        /// @notice Poseidon hash commitment to the secret number: hash(secret, salt)
        bytes32 commitment;
        /// @notice Prize amount awarded to the correct guesser
        uint256 bounty;
        /// @notice Optional slashable deposit showing creator commitment
        /// @dev If creator fails to respond within timeout, collateral is slashed to treasury.
        ///      Creators can set collateral=0 but risk losing bounty to timeout.
        uint256 collateral;
        /// @notice Minimum stake required per guess submission
        uint256 stakeRequired;
        /// @notice Maximum valid guess value (1 to maxNumber, max 65535 for 16-bit circuit)
        uint256 maxNumber;
        /// @notice Total number of challenges ever submitted to this puzzle
        uint256 challengeCount;
        /// @notice Number of challenges awaiting creator response
        uint256 pendingChallenges;
        /// @notice Timestamp of the most recent challenge submission
        uint256 lastChallengeTimestamp;
        /// @notice Timestamp of the most recent creator response to any challenge
        /// @dev Used to determine forfeit eligibility - creator must respond within RESPONSE_TIMEOUT
        uint256 lastResponseTime;
        /// @notice Snapshot of pending challenges at forfeit time (for claim distribution)
        uint256 pendingAtForfeit;
    }

    /// @notice Represents a guess challenge submitted by a player
    struct Challenge {
        /// @notice Address that submitted this guess
        address guesser;
        /// @notice True if creator has responded to this challenge with a proof
        bool responded;
        /// @notice The guessed number
        uint256 guess;
        /// @notice Amount staked by the guesser
        uint256 stake;
        /// @notice Block timestamp when the challenge was submitted
        uint256 timestamp;
    }

    // ============ Events ============

    /// @notice Emitted when a new puzzle is created
    event PuzzleCreated(
        uint256 indexed puzzleId, address creator, bytes32 commitment, uint256 bounty, uint256 maxNumber
    );

    /// @notice Emitted when a guesser submits a challenge
    event ChallengeCreated(uint256 indexed challengeId, uint256 indexed puzzleId, address guesser, uint256 guess);

    /// @notice Emitted when creator responds to a challenge with a ZK proof
    event ChallengeResponded(uint256 indexed challengeId, bool correct);

    /// @notice Emitted when a puzzle is solved by a correct guess
    event PuzzleSolved(uint256 indexed puzzleId, address winner, uint256 prize);

    /// @notice Emitted when creator cancels their puzzle
    event PuzzleCancelled(uint256 indexed puzzleId);

    /// @notice Emitted when a puzzle is forfeited due to creator inactivity
    event PuzzleForfeited(uint256 indexed puzzleId);

    /// @notice Emitted when collateral is slashed to treasury on forfeit
    event CollateralSlashed(uint256 indexed puzzleId, uint256 amount);

    /// @notice Emitted when a guesser claims their share from a forfeited puzzle
    event ForfeitClaimed(uint256 indexed puzzleId, address guesser, uint256 amount);

    /// @notice Emitted when a guesser claims their stake back from a solved puzzle
    event StakeClaimedFromSolved(uint256 indexed puzzleId, address guesser, uint256 stake);

    /// @notice Emitted when a user withdraws their accumulated balance
    event Withdrawal(address indexed account, uint256 amount);

    // ============ Errors ============

    /// @notice Thrown when puzzle creation value is below MIN_BOUNTY
    error InsufficientBounty();

    /// @notice Thrown when stake required is below MIN_STAKE
    error InsufficientStake();

    /// @notice Thrown when trying to interact with an already solved puzzle
    error PuzzleAlreadySolved();

    /// @notice Thrown when trying to interact with a cancelled puzzle
    error PuzzleCancelledError();

    /// @notice Thrown when trying to interact with a forfeited puzzle
    error PuzzleForfeitedError();

    /// @notice Thrown when trying to respond to an already responded challenge
    error ChallengeAlreadyResponded();

    /// @notice Thrown when non-creator tries to respond to a challenge
    error OnlyPuzzleCreator();

    /// @notice Thrown when ZK proof verification fails
    error InvalidProof();

    /// @notice Thrown when proof public signals don't match challenge parameters
    error InvalidProofForChallengeGuess();

    /// @notice Thrown when referencing a non-existent challenge
    error ChallengeNotFound();

    /// @notice Thrown when referencing a non-existent puzzle
    error PuzzleNotFound();

    /// @notice Thrown when initializing with zero verifier address
    error InvalidVerifierAddress();

    /// @notice Thrown when initializing with zero owner address
    error InvalidOwnerAddress();

    /// @notice Thrown when there's nothing to claim
    error NothingToClaim();

    /// @notice Thrown when trying to cancel with pending challenges
    error HasPendingChallenges();

    /// @notice Thrown when trying to cancel before CANCEL_TIMEOUT elapsed
    error CancelTooSoon();

    /// @notice Thrown when ETH transfer fails
    error TransferFailed();

    /// @notice Thrown when trying to forfeit but creator is still active (responded within timeout)
    error CreatorStillActive();

    /// @notice Thrown when challenge doesn't belong to caller
    error NotYourChallenge();

    /// @notice Thrown when trying to claim from non-forfeited puzzle
    error PuzzleNotForfeited();

    /// @notice Thrown when trying to claim stake from non-solved puzzle
    error PuzzleNotSolved();

    /// @notice Thrown when puzzle creator tries to guess their own puzzle
    error CreatorCannotGuess();

    /// @notice Thrown when trying to claim twice
    error AlreadyClaimed();

    /// @notice Thrown when trying to withdraw with zero balance
    error NothingToWithdraw();

    /// @notice Thrown when submitting duplicate guess for same puzzle
    error GuessAlreadySubmitted();

    /// @notice Thrown when guess is outside valid range (1 to maxNumber)
    error InvalidGuessRange();

    /// @notice Thrown when maxNumber exceeds circuit limit (65535)
    error InvalidMaxNumber();

    // ============ Functions ============

    /// @notice Create a new puzzle with a commitment to a secret number
    /// @param commitment Poseidon hash of (secret, salt)
    /// @param stakeRequired Minimum stake per guess (must be >= MIN_STAKE)
    /// @param maxNumber Maximum valid guess (1 to 65535)
    /// @return puzzleId The ID of the created puzzle
    /// @dev msg.value is split: bounty goes to prize pool, remainder is optional collateral
    function createPuzzle(bytes32 commitment, uint256 stakeRequired, uint256 maxNumber)
        external
        payable
        returns (uint256 puzzleId);

    /// @notice Submit a guess for a puzzle
    /// @param puzzleId The puzzle to guess on
    /// @param guess The guessed number (must be 1 to maxNumber)
    /// @return challengeId The ID of the created challenge
    /// @dev msg.value must be >= stakeRequired. Stake is returned on response.
    function submitGuess(uint256 puzzleId, uint256 guess) external payable returns (uint256 challengeId);

    /// @notice Respond to a challenge with a ZK proof
    /// @param puzzleId The puzzle the challenge belongs to
    /// @param challengeId The challenge to respond to
    /// @param _pA First component of the Groth16 proof
    /// @param _pB Second component of the Groth16 proof
    /// @param _pC Third component of the Groth16 proof
    /// @param _pubSignals Public signals: [commitment, isCorrect, guess, maxNumber]
    /// @dev Creator proves knowledge of secret without revealing it.
    ///      isCorrect=1 means guess matches secret (puzzle solved, guesser wins).
    ///      isCorrect=0 means wrong guess (guesser gets stake back).
    function respondToChallenge(
        uint256 puzzleId,
        uint256 challengeId,
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[4] calldata _pubSignals
    ) external;

    /// @notice Cancel a puzzle and reclaim bounty + collateral
    /// @param puzzleId The puzzle to cancel
    /// @dev Only callable by creator when no pending challenges exist
    ///      and CANCEL_TIMEOUT has elapsed since last challenge
    function cancelPuzzle(uint256 puzzleId) external;

    /// @notice Forfeit a puzzle when creator has been inactive
    /// @param puzzleId The puzzle to forfeit
    /// @param timedOutChallengeId Any pending challenge (for verification)
    /// @dev Callable by anyone if creator hasn't responded to any challenge within RESPONSE_TIMEOUT.
    ///      Collateral (if any) is slashed to treasury. Pending guessers can claim bounty shares.
    function forfeitPuzzle(uint256 puzzleId, uint256 timedOutChallengeId) external;

    /// @notice Claim stake and bounty share from a forfeited puzzle
    /// @param puzzleId The forfeited puzzle
    /// @dev One claim per guesser. Amount = stake + (bounty / pendingAtForfeit)
    function claimFromForfeited(uint256 puzzleId) external;

    /// @notice Claim stake back from a solved puzzle (for non-winners)
    /// @param puzzleId The solved puzzle
    /// @dev Only for guessers who didn't win. Winners are paid immediately.
    function claimStakeFromSolved(uint256 puzzleId) external;

    /// @notice Withdraw accumulated balance from claims
    function withdraw() external;

    /// @notice Time creator must wait after last challenge before cancelling
    function CANCEL_TIMEOUT() external view returns (uint256);

    /// @notice Time creator has to respond to at least one challenge before forfeit is allowed
    function RESPONSE_TIMEOUT() external view returns (uint256);

    /// @notice Minimum bounty required to create a puzzle
    function MIN_BOUNTY() external view returns (uint256);

    /// @notice Minimum stake required per guess
    function MIN_STAKE() external view returns (uint256);

    /// @notice Get puzzle details
    function getPuzzle(uint256 puzzleId) external view returns (Puzzle memory);

    /// @notice Get challenge details
    function getChallenge(uint256 puzzleId, uint256 challengeId) external view returns (Challenge memory);

    /// @notice Total number of puzzles created
    function puzzleCount() external view returns (uint256);

    /// @notice Internal balances available for withdrawal
    function balances(address account) external view returns (uint256);
}
