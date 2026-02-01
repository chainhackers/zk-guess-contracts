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
    uint256[2] validProofACorrect = [
        449531149912136475770353363361707418564909687680427115646129927332134531208,
        14407370880265595278678350402832836798818885365896905083843433929267668266626
    ];
    uint256[2][2] validProofBCorrect = [
        [
            17312921197632836956585949276008014848208220036975940402101347538989464726893,
            14649255969675641484092917911181181213459734554739828453996711367430887656035
        ],
        [
            19731250186663773803803693244597055364914729377868353692576144118343135911407,
            17184617509137607503905361228458251326217701668871035762567589018625184554749
        ]
    ];
    uint256[2] validProofCCorrect = [
        21835658683758097992725297997527117386568439008454908069273763801277098932784,
        9971757975327911076401779803594069722995141305793117329654742372844894117060
    ];

    uint256[2] validProofAIncorrect = [
        10852066913978342118218498818335408844066258321902599194444720468359168576214,
        6965698820638077395094099877008034652702640564558429698785929019854255895452
    ];
    uint256[2][2] validProofBIncorrect = [
        [
            1613230777238805011830229517807176666334104047967446217283376846766348057999,
            4374229236798730817553670335020809672579377927876284581397418664965153211023
        ],
        [
            4520893247875616557226868523444705263309850113066582487089193591474052220970,
            7766575812497568221119740140062493894108981945203859417355220016465955717634
        ]
    ];
    uint256[2] validProofCIncorrect = [
        4156351497089605839121606963169954792875252974032590314960492405100124400333,
        6066764750676488417561440637467884321186918175528620457428676808171983539025
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

        try game.createPuzzle{value: totalAmount}(COMMITMENT_42_123, stakeRequired, 100) returns (uint256 puzzleId) {
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

            uint256[4] memory pubSignals = [uint256(COMMITMENT_42_123), isCorrect ? 1 : 0, 42, 100];

            try game.respondToChallenge(
                puzzleId,
                challengeId,
                isCorrect ? validProofACorrect : validProofAIncorrect,
                isCorrect ? validProofBCorrect : validProofBIncorrect,
                isCorrect ? validProofCCorrect : validProofCIncorrect,
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
