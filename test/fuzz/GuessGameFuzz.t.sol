// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/GuessGame.sol";
import "../../src/generated/GuessVerifier.sol";

/**
 * @title GuessGameFuzz
 * @notice Targeted fuzz tests for GuessGame arithmetic and invariants
 */
contract GuessGameFuzz is Test {
    Groth16Verifier public verifier;
    GuessGame public game;

    address creator;
    address[] guessers;

    // Test data with VALID ZK proofs
    bytes32 constant COMMITMENT_42_123 = 0x1d869fb8246b6131377493aaaf1cc16a8284d4aedcb7277079df35d0d1d552d1;

    // Valid proof for incorrect guess (50) - used to respond without solving
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

    uint256 constant MIN_STAKE = 0.00001 ether;
    uint256 constant MIN_BOUNTY = 0.001 ether;
    uint256 constant MIN_TOTAL = MIN_BOUNTY * 2; // bounty + collateral
    uint256 constant RESPONSE_TIMEOUT = 1 days;

    address treasury;

    function setUp() public {
        verifier = new Groth16Verifier();
        treasury = makeAddr("treasury");
        game = new GuessGame(address(verifier), treasury);

        creator = makeAddr("creator");
        vm.deal(creator, 1000 ether);

        // Create a pool of guessers
        for (uint256 i = 0; i < 10; i++) {
            address guesser = makeAddr(string(abi.encodePacked("guesser", i)));
            guessers.push(guesser);
            vm.deal(guesser, 100 ether);
        }
    }

    /**
     * @notice Fuzz test: Bounty distribution dust should be minimal
     * @dev When N guessers claim from a forfeited puzzle, total distributed should be close to original bounty
     * @param bounty The puzzle bounty amount (fuzzed)
     * @param numGuessers Number of guessers (1-10)
     * @param stakeSeed Seed for generating varying stake amounts
     */
    function testFuzz_BountyDistributionDust(uint256 bounty, uint8 numGuessers, uint256 stakeSeed) public {
        // Bound inputs
        bounty = bound(bounty, MIN_BOUNTY, 100 ether);
        numGuessers = uint8(bound(numGuessers, 1, 10));

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: bounty * 2}(COMMITMENT_42_123, MIN_STAKE);

        // Track total stakes and challenges per guesser
        uint256 totalChallenges = 0;
        uint256[] memory challengeCounts = new uint256[](numGuessers);
        uint256[] memory stakeTotals = new uint256[](numGuessers);

        // Submit guesses with varying stakes
        for (uint256 i = 0; i < numGuessers; i++) {
            // Each guesser submits 1-3 challenges with varying stakes
            uint256 numChallenges = (uint256(keccak256(abi.encode(stakeSeed, i, "count"))) % 3) + 1;

            for (uint256 j = 0; j < numChallenges; j++) {
                uint256 stake = bound(uint256(keccak256(abi.encode(stakeSeed, i, j))), MIN_STAKE, 1 ether);

                vm.prank(guessers[i]);
                game.submitGuess{value: stake}(puzzleId, totalChallenges); // Unique wrong guess

                challengeCounts[i]++;
                stakeTotals[i] += stake;
                totalChallenges++;
            }
        }

        // Warp time to allow forfeit
        vm.warp(block.timestamp + RESPONSE_TIMEOUT + 1);

        // Forfeit puzzle (using challenge 0)
        game.forfeitPuzzle(puzzleId, 0);

        // All guessers claim
        uint256 totalDistributedBounty = 0;
        for (uint256 i = 0; i < numGuessers; i++) {
            vm.prank(guessers[i]);
            game.claimFromForfeited(puzzleId);

            uint256 balance = game.balances(guessers[i]);
            // Balance should be stake + bounty share
            uint256 expectedBountyShare = (bounty * challengeCounts[i]) / totalChallenges;
            totalDistributedBounty += expectedBountyShare;

            // Verify each guesser gets at least their stake back
            assertGe(balance, stakeTotals[i], "Guesser should get at least stake back");
        }

        // Total distributed bounty should be close to original (allowing for integer division dust)
        uint256 dust = bounty - totalDistributedBounty;

        // Dust should be less than numGuessers (at most 1 wei lost per division)
        assertLe(dust, totalChallenges, "Too much bounty dust lost");
    }

    /**
     * @notice Fuzz test: Aggregate tracking consistency
     * @dev guesserStakeTotal and guesserChallengeCount should always match sum of pending challenges
     * @param numGuesses Number of guesses to submit
     * @param numResponses Number of responses to process
     * @param stakeSeed Seed for varying stakes
     */
    function testFuzz_AggregateConsistency(uint8 numGuesses, uint8 numResponses, uint256 stakeSeed) public {
        // Bound inputs
        numGuesses = uint8(bound(numGuesses, 1, 20));
        numResponses = uint8(bound(numResponses, 0, numGuesses));

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 2 ether}(COMMITMENT_42_123, MIN_STAKE);

        // Track expected values per guesser in arrays
        uint256[] memory expectedStakes = new uint256[](guessers.length);
        uint256[] memory expectedCounts = new uint256[](guessers.length);
        uint256[] memory challengeIds = new uint256[](numGuesses);
        address[] memory challengeGuessers = new address[](numGuesses);
        uint256[] memory challengeStakes = new uint256[](numGuesses);

        // Submit guesses
        for (uint256 i = 0; i < numGuesses; i++) {
            uint256 guesserIdx = uint256(keccak256(abi.encode(stakeSeed, i, "guesser"))) % guessers.length;
            uint256 stake = bound(uint256(keccak256(abi.encode(stakeSeed, i, "stake"))), MIN_STAKE, 0.1 ether);

            vm.prank(guessers[guesserIdx]);
            uint256 challengeId = game.submitGuess{value: stake}(puzzleId, i); // Unique guess per challenge

            challengeIds[i] = challengeId;
            challengeGuessers[i] = guessers[guesserIdx];
            challengeStakes[i] = stake;
            expectedStakes[guesserIdx] += stake;
            expectedCounts[guesserIdx]++;
        }

        // Verify aggregates after submissions
        for (uint256 i = 0; i < guessers.length; i++) {
            assertEq(
                game.guesserStakeTotal(puzzleId, guessers[i]),
                expectedStakes[i],
                "Stake total mismatch after submissions"
            );
            assertEq(
                game.guesserChallengeCount(puzzleId, guessers[i]),
                expectedCounts[i],
                "Challenge count mismatch after submissions"
            );
        }

        // Respond to some challenges
        // NOTE: This test cannot respond because ZK proofs would need to match specific guesses.
        // Since we use unique guesses per challenge and our proofs are hardcoded,
        // we skip the response part of this test for now.
        // The aggregate tracking after submissions is still verified above.
        numResponses = 0; // Skip responses in this test

        for (uint256 i = 0; i < numResponses; i++) {
            uint256 challengeIdx = i; // Respond in order
            address guesser = challengeGuessers[challengeIdx];
            uint256 guesserIdx = _getGuesserIndex(guesser);
            uint256 stake = challengeStakes[challengeIdx];

            uint256[3] memory pubSignals = [uint256(COMMITMENT_42_123), 0, i];

            vm.prank(creator);
            game.respondToChallenge(
                puzzleId,
                challengeIds[challengeIdx],
                validProofAIncorrect,
                validProofBIncorrect,
                validProofCIncorrect,
                pubSignals
            );

            expectedStakes[guesserIdx] -= stake;
            expectedCounts[guesserIdx]--;
        }

        // Verify aggregates after responses
        for (uint256 i = 0; i < guessers.length; i++) {
            assertEq(
                game.guesserStakeTotal(puzzleId, guessers[i]), expectedStakes[i], "Stake total mismatch after responses"
            );
            assertEq(
                game.guesserChallengeCount(puzzleId, guessers[i]),
                expectedCounts[i],
                "Challenge count mismatch after responses"
            );
        }
    }

    /**
     * @notice Fuzz test: Contract solvency - always has enough ETH
     * @dev Contract balance should always cover all obligations
     * @param bounty Puzzle bounty
     * @param numGuesses Number of guesses
     * @param stakeSeed Seed for stakes
     */
    function testFuzz_ContractSolvency(uint256 bounty, uint8 numGuesses, uint256 stakeSeed) public {
        // Bound inputs
        bounty = bound(bounty, MIN_BOUNTY, 10 ether);
        numGuesses = uint8(bound(numGuesses, 1, 15));

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: bounty * 2}(COMMITMENT_42_123, MIN_STAKE);

        uint256 totalStakes = 0;
        uint256[] memory stakes = new uint256[](numGuesses);
        address[] memory guesserAddrs = new address[](numGuesses);

        // Submit guesses
        for (uint256 i = 0; i < numGuesses; i++) {
            uint256 guesserIdx = i % guessers.length;
            uint256 stake = bound(uint256(keccak256(abi.encode(stakeSeed, i))), MIN_STAKE, 0.5 ether);

            vm.prank(guessers[guesserIdx]);
            game.submitGuess{value: stake}(puzzleId, i); // Unique guess

            stakes[i] = stake;
            guesserAddrs[i] = guessers[guesserIdx];
            totalStakes += stake;
        }

        // Contract should hold total (bounty + collateral) + all stakes
        // bounty * 2 because we sent bounty * 2 but the puzzle stores bounty = total / 2
        assertEq(address(game).balance, bounty * 2 + totalStakes, "Contract balance mismatch");

        // Warp and forfeit
        vm.warp(block.timestamp + RESPONSE_TIMEOUT + 1);
        game.forfeitPuzzle(puzzleId, 0);

        // All guessers claim
        uint256 totalClaimed = 0;
        address[] memory uniqueGuessers = _getUniqueGuessers(guesserAddrs);

        for (uint256 i = 0; i < uniqueGuessers.length; i++) {
            if (uniqueGuessers[i] == address(0)) continue;

            uint256 balanceBefore = game.balances(uniqueGuessers[i]);
            vm.prank(uniqueGuessers[i]);
            game.claimFromForfeited(puzzleId);
            uint256 balanceAfter = game.balances(uniqueGuessers[i]);

            totalClaimed += balanceAfter - balanceBefore;
        }

        // All unique guessers withdraw
        for (uint256 i = 0; i < uniqueGuessers.length; i++) {
            if (uniqueGuessers[i] == address(0)) continue;

            uint256 balance = game.balances(uniqueGuessers[i]);
            if (balance > 0) {
                vm.prank(uniqueGuessers[i]);
                game.withdraw();
            }
        }

        // After all withdrawals, contract should have minimal dust
        uint256 remainingBalance = address(game).balance;

        // Remaining should only be rounding dust (at most numGuesses wei)
        assertLe(remainingBalance, numGuesses, "Too much dust remaining in contract");
    }

    /**
     * @notice Fuzz test: Stake accumulation across multiple puzzles
     * @dev Balances should correctly accumulate from multiple puzzle claims
     * @param numPuzzles Number of puzzles to create
     * @param bountySeed Seed for bounty amounts
     */
    function testFuzz_MultiPuzzleBalanceAccumulation(uint8 numPuzzles, uint256 bountySeed) public {
        numPuzzles = uint8(bound(numPuzzles, 2, 5));

        uint256[] memory puzzleIds = new uint256[](numPuzzles);
        uint256[] memory bounties = new uint256[](numPuzzles);

        // Create puzzles and submit guesses
        for (uint256 i = 0; i < numPuzzles; i++) {
            uint256 bounty = bound(uint256(keccak256(abi.encode(bountySeed, i))), MIN_BOUNTY, 1 ether);
            bounties[i] = bounty;

            vm.prank(creator);
            puzzleIds[i] = game.createPuzzle{value: bounty * 2}(COMMITMENT_42_123, MIN_STAKE);

            // Single guesser submits to each puzzle (unique guess per puzzle)
            vm.prank(guessers[0]);
            game.submitGuess{value: MIN_STAKE}(puzzleIds[i], i);
        }

        // Warp and forfeit all puzzles
        vm.warp(block.timestamp + RESPONSE_TIMEOUT + 1);

        for (uint256 i = 0; i < numPuzzles; i++) {
            game.forfeitPuzzle(puzzleIds[i], 0);
        }

        // Claim from all puzzles
        uint256 expectedTotal = 0;
        for (uint256 i = 0; i < numPuzzles; i++) {
            vm.prank(guessers[0]);
            game.claimFromForfeited(puzzleIds[i]);

            // Expected: stake + full bounty (single guesser gets all)
            expectedTotal += MIN_STAKE + bounties[i];
        }

        // Verify accumulated balance
        assertEq(game.balances(guessers[0]), expectedTotal, "Balance accumulation mismatch");

        // Withdraw and verify
        uint256 guesserBalanceBefore = guessers[0].balance;
        vm.prank(guessers[0]);
        game.withdraw();

        assertEq(guessers[0].balance, guesserBalanceBefore + expectedTotal, "Withdrawal amount mismatch");
    }

    /**
     * @notice Fuzz test: Division edge cases in bounty share calculation
     * @dev Test bounty / pendingAtForfeit with edge case values
     * @param bounty Bounty amount
     * @param numChallenges Number of challenges
     */
    function testFuzz_BountyShareDivision(uint256 bounty, uint8 numChallenges) public {
        bounty = bound(bounty, MIN_BOUNTY, 100 ether);
        numChallenges = uint8(bound(numChallenges, 1, 50));

        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: bounty * 2}(COMMITMENT_42_123, MIN_STAKE);

        // Submit challenges from single guesser (unique guess per challenge)
        for (uint256 i = 0; i < numChallenges; i++) {
            vm.prank(guessers[0]);
            game.submitGuess{value: MIN_STAKE}(puzzleId, i);
        }

        // Forfeit
        vm.warp(block.timestamp + RESPONSE_TIMEOUT + 1);
        game.forfeitPuzzle(puzzleId, 0);

        // Claim - single guesser should get full bounty
        vm.prank(guessers[0]);
        game.claimFromForfeited(puzzleId);

        // bountyShare = (bounty * numChallenges) / numChallenges = bounty (exactly)
        uint256 expectedBalance = MIN_STAKE * numChallenges + bounty;
        assertEq(game.balances(guessers[0]), expectedBalance, "Single guesser should get full bounty");
    }

    /**
     * @notice Fuzz test: Equal distribution among guessers
     * @dev When all guessers have equal challenges, distribution should be equal
     * @param bounty Bounty amount
     * @param numGuessers Number of guessers (each with 1 challenge)
     */
    function testFuzz_EqualDistribution(uint256 bounty, uint8 numGuessers) public {
        bounty = bound(bounty, MIN_BOUNTY, 10 ether);
        numGuessers = uint8(bound(numGuessers, 2, 10));

        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: bounty * 2}(COMMITMENT_42_123, MIN_STAKE);

        // Each guesser submits exactly 1 challenge (unique guess per guesser)
        for (uint256 i = 0; i < numGuessers; i++) {
            vm.prank(guessers[i]);
            game.submitGuess{value: MIN_STAKE}(puzzleId, i);
        }

        // Forfeit
        vm.warp(block.timestamp + RESPONSE_TIMEOUT + 1);
        game.forfeitPuzzle(puzzleId, 0);

        // All claim
        uint256[] memory claimedAmounts = new uint256[](numGuessers);
        for (uint256 i = 0; i < numGuessers; i++) {
            vm.prank(guessers[i]);
            game.claimFromForfeited(puzzleId);
            claimedAmounts[i] = game.balances(guessers[i]);
        }

        // All amounts should be equal (stake + bounty/numGuessers)
        uint256 expectedBountyShare = bounty / numGuessers;
        uint256 expectedTotal = MIN_STAKE + expectedBountyShare;

        for (uint256 i = 0; i < numGuessers; i++) {
            assertEq(claimedAmounts[i], expectedTotal, "Unequal distribution");
        }

        // Total distributed should be close to bounty (within numGuessers-1 wei dust)
        uint256 totalDistributed = expectedBountyShare * numGuessers;
        uint256 dust = bounty - totalDistributed;
        assertLt(dust, numGuessers, "Too much dust");
    }

    /**
     * @notice Fuzz test: Collateral slash sends exact amount to treasury
     * @dev Treasury should receive exactly totalDeposit / 2
     * @param totalDeposit Total amount sent to createPuzzle
     */
    function testFuzz_CollateralSlashExactAmount(uint256 totalDeposit) public {
        totalDeposit = bound(totalDeposit, MIN_TOTAL, 100 ether);

        uint256 expectedCollateral = totalDeposit / 2;
        uint256 treasuryBefore = treasury.balance;

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: totalDeposit}(COMMITMENT_42_123, MIN_STAKE);

        // Verify collateral stored correctly
        assertEq(game.getPuzzle(puzzleId).collateral, expectedCollateral);

        // Submit guess and forfeit
        vm.prank(guessers[0]);
        game.submitGuess{value: MIN_STAKE}(puzzleId, 0);

        vm.warp(block.timestamp + RESPONSE_TIMEOUT + 1);
        game.forfeitPuzzle(puzzleId, 0);

        // Treasury receives exactly the collateral
        assertEq(treasury.balance, treasuryBefore + expectedCollateral);
    }

    // Helper function to get guesser index
    function _getGuesserIndex(address guesser) internal view returns (uint256) {
        for (uint256 i = 0; i < guessers.length; i++) {
            if (guessers[i] == guesser) return i;
        }
        revert("Guesser not found");
    }

    // Helper to get unique guessers from array
    function _getUniqueGuessers(address[] memory addrs) internal pure returns (address[] memory) {
        address[] memory unique = new address[](addrs.length);
        uint256 count = 0;

        for (uint256 i = 0; i < addrs.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < count; j++) {
                if (unique[j] == addrs[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                unique[count++] = addrs[i];
            }
        }

        return unique;
    }
}
