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
    address public immutable treasury;

    // Ghost variables for tracking state
    mapping(uint256 => bool) public ghostPuzzleExists;
    mapping(uint256 => bool) public ghostPuzzleSolved;
    mapping(uint256 => bool) public ghostPuzzleCancelled;
    mapping(uint256 => bool) public ghostPuzzleForfeited;
    mapping(uint256 => uint256) public ghostPuzzleBounty; // bounty per puzzle
    mapping(uint256 => uint256) public ghostPuzzleCollateral; // collateral per puzzle
    mapping(uint256 => uint256) public ghostPuzzlePendingStakes; // sum of pending stakes per puzzle
    uint256 public ghostTotalContractFunds;
    uint256 public ghostTreasuryReceived; // total ETH sent to treasury
    mapping(uint256 => address) public ghostPuzzleCreator; // creator per puzzle

    // Track unique guesses per puzzle to avoid duplicate revert
    mapping(uint256 => uint256) public nextGuessNumber;

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
        20733104445222474913460899055922638733390515415268774731643134142498872084191,
        14000468808382636465462761302394038173719213862863751644422554851223456811411
    ];
    uint256[2][2] validProofB_correct = [
        [
            14529324359401080920218683234881556919213052277135946418796017114639319774385,
            12129083737057255635218975576710777788141717515839459178762095078342656790038
        ],
        [
            4006130398494418696741732007622629431845312574338850368957129174821663088541,
            5320382245369139568202711526684359871618209808068963385672210545364024687600
        ]
    ];
    uint256[2] validProofC_correct = [
        11555678601106434654959630063997038302724273931564919993607610338934924583422,
        12395595758571672800576038452878068084738676055843400774526791354550122500902
    ];

    uint256[2] validProofA_incorrect = [
        260224852269514550962255596791713148069192103530930225168509498623216740997,
        3464936673232863366747749560095954607406672448198506930195439109614243395305
    ];
    uint256[2][2] validProofB_incorrect = [
        [
            18076787037990225159899307248733301104058781270403724423075272532649526747523,
            21163582130445499238873337568384386692136208661991064222861763232945956209076
        ],
        [
            14700551543044113104786011479044690264965500866720142037325671448170897252180,
            248536395010580566114959855988956594661021088223112251086687402479116093507
        ]
    ];
    uint256[2] validProofC_incorrect = [
        3718774677296111965628987936986701738438916711731522663485615268638604855259,
        15664470303899517099778638779831003600948012776255763324223926677414563225933
    ];

    bytes32 constant COMMITMENT_42_123 = 0x1d869fb8246b6131377493aaaf1cc16a8284d4aedcb7277079df35d0d1d552d1;

    constructor(GuessGame _game, Groth16Verifier _verifier, address _treasury) {
        game = _game;
        verifier = _verifier;
        treasury = _treasury;

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

    function _isPuzzleActive(uint256 puzzleId) internal view returns (bool) {
        return ghostPuzzleExists[puzzleId] && !ghostPuzzleSolved[puzzleId] && !ghostPuzzleCancelled[puzzleId]
            && !ghostPuzzleForfeited[puzzleId];
    }

    // Handler functions
    function createPuzzle(uint256 bountyAmount, uint256 stakeRequired, uint256 creatorSeed)
        public
        boundBounty(bountyAmount)
        boundStake(stakeRequired)
        useActor(creators, creatorSeed)
    {
        // Calculate total amount (bounty + collateral, 1:1)
        uint256 totalAmount = bountyAmount * 2;

        // Fund the creator
        vm.deal(creators[creatorSeed % creators.length], totalAmount);

        try game.createPuzzle{value: totalAmount}(COMMITMENT_42_123, stakeRequired) returns (uint256 puzzleId) {
            // Update ghost variables (bounty is half of total)
            ghostPuzzleExists[puzzleId] = true;
            ghostPuzzleBounty[puzzleId] = bountyAmount;
            ghostPuzzleCollateral[puzzleId] = bountyAmount;
            ghostPuzzleCreator[puzzleId] = creators[creatorSeed % creators.length];
            ghostTotalContractFunds += totalAmount;
        } catch {
            // Ignore reverts
        }
    }

    function submitGuess(uint256 puzzleId, uint256, uint256 stakeAmount, uint256 guesserSeed)
        public
        boundStake(stakeAmount)
        useActor(guessers, guesserSeed)
    {
        if (!_isPuzzleActive(puzzleId)) return;

        // Use unique guess number to avoid GuessAlreadySubmitted error
        uint256 uniqueGuess = nextGuessNumber[puzzleId];
        nextGuessNumber[puzzleId]++;

        // Fund the guesser
        vm.deal(guessers[guesserSeed % guessers.length], stakeAmount);

        try game.submitGuess{value: stakeAmount}(puzzleId, uniqueGuess) returns (uint256) {
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
        if (!_isPuzzleActive(puzzleId)) return;

        // Get challenge info
        try game.getChallenge(puzzleId, challengeId) returns (IGuessGame.Challenge memory challenge) {
            if (challenge.guesser == address(0) || challenge.responded) return;

            uint256[3] memory pubSignals = [uint256(COMMITMENT_42_123), isCorrect ? 1 : 0, 42];

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
                    // Puzzle solved - bounty goes to winner, collateral goes to creator's internal balance
                    ghostPuzzleSolved[puzzleId] = true;
                    ghostTotalContractFunds -= ghostPuzzleBounty[puzzleId];
                    // Collateral stays in contract (credited to creator's internal balance)
                    // so we don't subtract it from ghostTotalContractFunds
                    ghostPuzzleBounty[puzzleId] = 0;
                }
            } catch {
                // Ignore reverts
            }
        } catch {
            // Ignore if challenge doesn't exist
        }
    }

    function cancelPuzzle(uint256 puzzleId, uint256 creatorSeed, uint256 timeWarp)
        public
        useActor(creators, creatorSeed)
    {
        if (!_isPuzzleActive(puzzleId)) return;

        // Optionally warp time to allow cancellation after timeout
        uint256 warpAmount = bound(timeWarp, 0, 2 days);
        if (warpAmount > 0) {
            vm.warp(block.timestamp + warpAmount);
        }

        try game.getPuzzle(puzzleId) returns (IGuessGame.Puzzle memory puzzle) {
            if (puzzle.creator != creators[creatorSeed % creators.length]) return;
            if (puzzle.pendingChallenges > 0) return;

            try game.cancelPuzzle(puzzleId) {
                // Update ghost variables (bounty + collateral returned to creator)
                ghostPuzzleCancelled[puzzleId] = true;
                ghostTotalContractFunds -= ghostPuzzleBounty[puzzleId] + ghostPuzzleCollateral[puzzleId];
                ghostPuzzleBounty[puzzleId] = 0;
                ghostPuzzleCollateral[puzzleId] = 0;
            } catch {
                // Ignore reverts (including CancelTooSoon)
            }
        } catch {
            // Ignore
        }
    }

    function forfeitPuzzle(uint256 puzzleId, uint256 challengeId, uint256 timeWarp) public {
        if (!_isPuzzleActive(puzzleId)) return;

        // Warp time to allow forfeit
        uint256 warpAmount = bound(timeWarp, 0, 2 days);
        if (warpAmount > 0) {
            vm.warp(block.timestamp + warpAmount);
        }

        try game.forfeitPuzzle(puzzleId, challengeId) {
            // Update ghost variables
            ghostPuzzleForfeited[puzzleId] = true;
            // Collateral is slashed to treasury
            uint256 collateral = ghostPuzzleCollateral[puzzleId];
            ghostTreasuryReceived += collateral;
            ghostTotalContractFunds -= collateral;
            ghostPuzzleCollateral[puzzleId] = 0;
            // Note: bounty and stakes will be distributed via claims
        } catch {
            // Ignore reverts
        }
    }

    function claimFromForfeited(uint256 puzzleId, uint256 guesserSeed) public useActor(guessers, guesserSeed) {
        if (!ghostPuzzleForfeited[puzzleId]) return;

        address guesser = guessers[guesserSeed % guessers.length];

        try game.getPuzzle(puzzleId) returns (IGuessGame.Puzzle memory puzzle) {
            // Get guesser's stake and challenge count
            uint256 myStake = game.guesserStakeTotal(puzzleId, guesser);
            uint256 myChallenges = game.guesserChallengeCount(puzzleId, guesser);

            if (myChallenges == 0) return;
            if (game.guesserClaimed(puzzleId, guesser)) return;

            uint256 bountyShare = (puzzle.bounty * myChallenges) / puzzle.pendingAtForfeit;
            uint256 totalPayout = myStake + bountyShare;

            try game.claimFromForfeited(puzzleId) {
                // Update ghost variables - credits internal balance, doesn't transfer yet
                ghostPuzzlePendingStakes[puzzleId] -= myStake;
                // Note: ghostTotalContractFunds stays same until withdraw
            } catch {
                // Ignore reverts
            }
        } catch {
            // Ignore
        }
    }

    // Helper to sum all active puzzle funds
    function sumActivePuzzleFunds() public view returns (uint256 total) {
        uint256 puzzleCount = game.puzzleCount();
        for (uint256 i = 0; i < puzzleCount; i++) {
            if (_isPuzzleActive(i)) {
                // Include bounty + collateral + pending stakes
                total += ghostPuzzleBounty[i] + ghostPuzzleCollateral[i] + ghostPuzzlePendingStakes[i];
            } else if (ghostPuzzleForfeited[i]) {
                // For forfeited puzzles, include unclaimed funds (collateral goes to treasury)
                IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
                if (puzzle.pendingChallenges > 0) {
                    // Still has pending claims (bounty + stakes, collateral already sent to treasury)
                    total += ghostPuzzleBounty[i] + ghostPuzzlePendingStakes[i];
                }
            }
        }
    }
}
