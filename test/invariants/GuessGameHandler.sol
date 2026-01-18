// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/GuessGame.sol";
import "../../src/generated/GuessVerifier.sol";

/**
 * @title GuessGameHandler
 * @notice Handler contract for invariant testing that performs bounded actions on GuessGame
 * @dev Tracks ghost variables to help verify invariants
 */
contract GuessGameHandler is Test {
    GuessGame public immutable game;
    Groth16Verifier public immutable verifier;

    // Ghost variables for tracking state
    mapping(uint256 => bool) public ghostPuzzleExists;
    mapping(uint256 => bool) public ghostPuzzleSolved;
    mapping(uint256 => bool) public ghostPuzzleCancelled;
    mapping(uint256 => uint256) public ghostPuzzleBounty; // bounty per puzzle
    mapping(uint256 => uint256) public ghostPuzzlePendingStakes; // sum of pending stakes per puzzle
    uint256 public ghostTotalContractFunds;

    // Actors
    address[] public creators;
    address[] public guessers;

    // Bounds for fuzzing
    uint256 constant MIN_STAKE = 0.001 ether;
    uint256 constant MAX_STAKE = 1 ether;
    uint256 constant MIN_BOUNTY = 0.001 ether;
    uint256 constant MAX_BOUNTY = 10 ether;

    // Valid proofs for testing (from actual circuit)
    uint256[2] validProofA_correct = [
        5157887698177337623115911855277593515678867316837177621945040770006555507013,
        2906418579536343400716582440049667062559269406745718123049284811979351078961
    ];
    uint256[2][2] validProofB_correct = [
        [
            14332055634374331006889483633092758827337849388827220354213364180982843452222,
            19810903419040124121233668365857833379920314502394091870176177029284861054627
        ],
        [
            14914521979328201877060585819741683859740663954794671014405495630456970523413,
            5932921202897788419271490057837377976593298755559539853566958258387675310919
        ]
    ];
    uint256[2] validProofC_correct = [
        19225161834181317330543503779290557071354809366572782951390269839775729508986,
        2612633047517129916523257452953334712431527691991012490800657229613067565909
    ];

    uint256[2] validProofA_incorrect = [
        9758308845527562880152000047576342898199622908603024910972559233417444022851,
        13422093807828339412230457774329866784975316828562739791130382143618778496264
    ];
    uint256[2][2] validProofB_incorrect = [
        [
            9091300984639239739423744708847319435452500770118051644787336315262064631896,
            2270884553819703540920998596410221495666419821064349332236675366442618568527
        ],
        [
            14277132759968817182426864918099654463588513402666202713843117479877941998171,
            2239514721205042574478060827327107365740006011919760432858530138062064747403
        ]
    ];
    uint256[2] validProofC_incorrect = [
        4604401960742347972625156994490312017011144396786495069487929528815195101025,
        10202941257821071730828470950370450429224326502691136785274183779399028461980
    ];

    bytes32 constant COMMITMENT_42_123 = 0x1d869fb8246b6131377493aaaf1cc16a8284d4aedcb7277079df35d0d1d552d1;

    constructor(GuessGame _game, Groth16Verifier _verifier) {
        game = _game;
        verifier = _verifier;

        // Initialize actors
        for (uint256 i = 0; i < 3; i++) {
            creators.push(address(uint160(0x1000 + i)));
            guessers.push(address(uint160(0x2000 + i)));
        }
    }

    // Modifiers to bound inputs
    modifier boundBounty(uint256 bounty) {
        bounty = bound(bounty, MIN_BOUNTY, MAX_BOUNTY);
        _;
    }

    modifier boundStake(uint256 stake) {
        stake = bound(stake, MIN_STAKE, MAX_STAKE);
        _;
    }

    modifier useActor(address[] memory actors, uint256 actorSeed) {
        address actor = actors[actorSeed % actors.length];
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    // Bound helper - override StdUtils
    function bound(uint256 x, uint256 min, uint256 max) internal pure override returns (uint256) {
        if (x < min) return min;
        if (x > max) return max;
        return x;
    }

    // Handler functions
    function createPuzzle(uint256 bountyAmount, uint256 stakeRequired, uint256 creatorSeed)
        public
        boundBounty(bountyAmount)
        boundStake(stakeRequired)
        useActor(creators, creatorSeed)
    {
        // Fund the creator
        vm.deal(creators[creatorSeed % creators.length], bountyAmount);

        try game.createPuzzle{value: bountyAmount}(COMMITMENT_42_123, stakeRequired) returns (uint256 puzzleId) {
            // Update ghost variables
            ghostPuzzleExists[puzzleId] = true;
            ghostPuzzleBounty[puzzleId] = bountyAmount;
            ghostTotalContractFunds += bountyAmount;
        } catch {
            // Ignore reverts
        }
    }

    function submitGuess(uint256 puzzleId, uint256 guess, uint256 stakeAmount, uint256 guesserSeed)
        public
        boundStake(stakeAmount)
        useActor(guessers, guesserSeed)
    {
        if (!ghostPuzzleExists[puzzleId] || ghostPuzzleSolved[puzzleId] || ghostPuzzleCancelled[puzzleId]) return;

        // Fund the guesser
        vm.deal(guessers[guesserSeed % guessers.length], stakeAmount);

        try game.submitGuess{value: stakeAmount}(puzzleId, guess) returns (uint256) {
            // Update ghost variables
            ghostPuzzlePendingStakes[puzzleId] += stakeAmount;
            ghostTotalContractFunds += stakeAmount;
        } catch {
            // Ignore reverts
        }
    }

    function respondToChallenge(uint256 puzzleId, uint256 challengeId, bool isCorrect, uint256 creatorSeed)
        public
        useActor(creators, creatorSeed)
    {
        if (!ghostPuzzleExists[puzzleId] || ghostPuzzleSolved[puzzleId] || ghostPuzzleCancelled[puzzleId]) return;

        // Get challenge info
        try game.getChallenge(puzzleId, challengeId) returns (IGuessGame.Challenge memory challenge) {
            if (challenge.guesser == address(0) || challenge.responded) return;

            uint256[2] memory pubSignals = [uint256(COMMITMENT_42_123), isCorrect ? 1 : 0];

            try game.respondToChallenge(
                puzzleId,
                challengeId,
                isCorrect ? validProofA_correct : validProofA_incorrect,
                isCorrect ? validProofB_correct : validProofB_incorrect,
                isCorrect ? validProofC_correct : validProofC_incorrect,
                pubSignals
            ) {
                // Stake is always returned to guesser
                ghostPuzzlePendingStakes[puzzleId] -= challenge.stake;
                ghostTotalContractFunds -= challenge.stake;

                if (isCorrect) {
                    // Puzzle solved - bounty also distributed
                    ghostPuzzleSolved[puzzleId] = true;
                    ghostTotalContractFunds -= ghostPuzzleBounty[puzzleId];
                    ghostPuzzleBounty[puzzleId] = 0;
                }
            } catch {
                // Ignore reverts
            }
        } catch {
            // Ignore if challenge doesn't exist
        }
    }

    function cancelPuzzle(uint256 puzzleId, uint256 creatorSeed, uint256 timeWarp) public useActor(creators, creatorSeed) {
        if (!ghostPuzzleExists[puzzleId] || ghostPuzzleSolved[puzzleId] || ghostPuzzleCancelled[puzzleId]) return;

        // Optionally warp time to allow cancellation after timeout
        uint256 warpAmount = bound(timeWarp, 0, 2 days);
        if (warpAmount > 0) {
            vm.warp(block.timestamp + warpAmount);
        }

        try game.getPuzzle(puzzleId) returns (IGuessGame.Puzzle memory puzzle) {
            if (puzzle.creator != creators[creatorSeed % creators.length]) return;
            if (puzzle.pendingChallenges > 0) return;

            try game.cancelPuzzle(puzzleId) {
                // Update ghost variables
                ghostPuzzleCancelled[puzzleId] = true;
                ghostTotalContractFunds -= ghostPuzzleBounty[puzzleId];
                ghostPuzzleBounty[puzzleId] = 0;
            } catch {
                // Ignore reverts (including CancelTooSoon)
            }
        } catch {
            // Ignore
        }
    }

    // Helper to sum all active puzzle funds
    function sumActivePuzzleFunds() public view returns (uint256 total) {
        uint256 puzzleCount = game.puzzleCount();
        for (uint256 i = 0; i < puzzleCount; i++) {
            if (ghostPuzzleExists[i] && !ghostPuzzleSolved[i] && !ghostPuzzleCancelled[i]) {
                total += ghostPuzzleBounty[i] + ghostPuzzlePendingStakes[i];
            }
        }
    }
}
