// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IGuessGame {
    struct Puzzle {
        address creator;
        bytes32 commitment;
        uint256 bounty;
        uint256 stakeRequired;
        uint8 bountyGrowthPercent;
        uint256 totalStaked;
        uint256 creatorReward;
        uint256 lastChallengeId;
        bool solved;
    }
    
    struct Challenge {
        address guesser;
        uint256 guess;
        uint256 stake;
        uint256 timestamp;
        uint256 prevChallengeId;
        bool responded;
    }
    
    // Events
    event PuzzleCreated(uint256 indexed puzzleId, address creator, bytes32 commitment, uint256 bounty);
    event ChallengeCreated(uint256 indexed challengeId, uint256 indexed puzzleId, address guesser, uint256 guess);
    event ChallengeResponded(uint256 indexed challengeId, bool correct);
    event PuzzleSolved(uint256 indexed puzzleId, address winner, uint256 prize);
    
    // Errors
    error InsufficientBounty();
    error InsufficientStake();
    error PuzzleAlreadySolved();
    error ChallengeAlreadyResponded();
    error OnlyPuzzleCreator();
    error InvalidProof();
    error ChallengeNotFound();
    error PuzzleNotFound();
    error InvalidGrowthPercent();
    error InvalidVerifierAddress();
    error NothingToClaim();
    error TransferToWinnerFailed();
    error TransferToCreatorFailed();
    error TransferToClaimerFailed();
    error InvalidChallengeResponseOrder();
    
    // Functions
    function createPuzzle(
        bytes32 commitment,
        uint256 stakeRequired,
        uint8 bountyGrowthPercent
    ) external payable returns (uint256 puzzleId);
    
    function submitGuess(
        uint256 puzzleId,
        uint256 guess
    ) external payable returns (uint256 challengeId);
    
    /**
     * @notice Respond to a challenge with a ZK proof
     * @param challengeId The challenge to respond to
     * @param _pA, _pB, _pC The proof components
     * @param _pubSignals Public signals: [commitment, isCorrect]
     *                    where isCorrect = 1 if guess matches secret, 0 otherwise
     * @dev The creator proves they know the secret (never revealed) and whether the guess is correct
     *      If correct: puzzle is solved, guesser wins bounty + stakes
     *      If incorrect: guesser loses stake, which is added to bounty
     */
    function respondToChallenge(
        uint256 challengeId,
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[2] calldata _pubSignals
    ) external;
    
    function getPuzzle(uint256 puzzleId) external view returns (Puzzle memory);
    function getChallenge(uint256 challengeId) external view returns (Challenge memory);
    function puzzleCount() external view returns (uint256);
    function challengeCount() external view returns (uint256);
}