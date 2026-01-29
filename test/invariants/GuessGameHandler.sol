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
        11504940021775654723396425733285520171636083270569085996696638875572788294702,
        20637774454469044945452272765979331202451395558074875764295247503932702604629
    ];
    uint256[2][2] validProofBCorrect = [
        [
            19724327737928428067436744771566894225255546895126133643853596733661323080944,
            13492609421459766523740584888043360210859595830002357517875974051598571449631
        ],
        [
            9101346022506809922940675743405360969490706785433757256514522858631885651223,
            12264233282322348000730820238906876741351433565392606730751196784147109643754
        ]
    ];
    uint256[2] validProofCCorrect = [
        17615922777476637143563646924700485140840791473300702105604187277711362783877,
        3483001149425582467351102259969255865622028834738135840359710692864323177598
    ];

    uint256[2] validProofAIncorrect = [
        17668304494923110155110008244216636870940265447331590922567454459053815694304,
        13683766786964868367848848655586138024784872326513979640650673946629532736401
    ];
    uint256[2][2] validProofBIncorrect = [
        [
            1945857558955814391241731181179539082141059668772203558278829707457186200701,
            12053699461649061725393751797387552055526376190469242430549646015289936822082
        ],
        [
            20996945187651455596783162227378312257353125457550519668673598026254799948352,
            1704003304756807228231582586456883401866958799709829924003555168741547960176
        ]
    ];
    uint256[2] validProofCIncorrect = [
        1862820214253159801867008017419693231512243420476638764645735501747594412631,
        1860067633072027579981620760559231595581410729592525645286971708351044373375
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
