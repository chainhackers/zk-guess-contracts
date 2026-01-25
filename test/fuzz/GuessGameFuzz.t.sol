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

    uint256 constant MIN_STAKE = 0.00001 ether;
    uint256 constant MIN_BOUNTY = 0.001 ether;
    uint256 constant RESPONSE_TIMEOUT = 1 days;

    function setUp() public {
        verifier = new Groth16Verifier();
        game = new GuessGame(address(verifier));

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
        uint256 puzzleId = game.createPuzzle{value: bounty}(COMMITMENT_42_123, MIN_STAKE);

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
                game.submitGuess{value: stake}(puzzleId, 50); // Wrong guess

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
        uint256 puzzleId = game.createPuzzle{value: 1 ether}(COMMITMENT_42_123, MIN_STAKE);

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
            uint256 challengeId = game.submitGuess{value: stake}(puzzleId, 50);

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
        for (uint256 i = 0; i < numResponses; i++) {
            uint256 challengeIdx = i; // Respond in order
            address guesser = challengeGuessers[challengeIdx];
            uint256 guesserIdx = _getGuesserIndex(guesser);
            uint256 stake = challengeStakes[challengeIdx];

            uint256[3] memory pubSignals = [uint256(COMMITMENT_42_123), 0, 50];

            vm.prank(creator);
            game.respondToChallenge(
                puzzleId,
                challengeIds[challengeIdx],
                validProofA_incorrect,
                validProofB_incorrect,
                validProofC_incorrect,
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
        uint256 puzzleId = game.createPuzzle{value: bounty}(COMMITMENT_42_123, MIN_STAKE);

        uint256 totalStakes = 0;
        uint256[] memory stakes = new uint256[](numGuesses);
        address[] memory guesserAddrs = new address[](numGuesses);

        // Submit guesses
        for (uint256 i = 0; i < numGuesses; i++) {
            uint256 guesserIdx = i % guessers.length;
            uint256 stake = bound(uint256(keccak256(abi.encode(stakeSeed, i))), MIN_STAKE, 0.5 ether);

            vm.prank(guessers[guesserIdx]);
            game.submitGuess{value: stake}(puzzleId, 50);

            stakes[i] = stake;
            guesserAddrs[i] = guessers[guesserIdx];
            totalStakes += stake;
        }

        // Contract should hold bounty + all stakes
        assertEq(address(game).balance, bounty + totalStakes, "Contract balance mismatch");

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
            puzzleIds[i] = game.createPuzzle{value: bounty}(COMMITMENT_42_123, MIN_STAKE);

            // Single guesser submits to each puzzle
            vm.prank(guessers[0]);
            game.submitGuess{value: MIN_STAKE}(puzzleIds[i], 50);
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
        uint256 puzzleId = game.createPuzzle{value: bounty}(COMMITMENT_42_123, MIN_STAKE);

        // Submit challenges from single guesser
        for (uint256 i = 0; i < numChallenges; i++) {
            vm.prank(guessers[0]);
            game.submitGuess{value: MIN_STAKE}(puzzleId, 50);
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
        uint256 puzzleId = game.createPuzzle{value: bounty}(COMMITMENT_42_123, MIN_STAKE);

        // Each guesser submits exactly 1 challenge
        for (uint256 i = 0; i < numGuessers; i++) {
            vm.prank(guessers[i]);
            game.submitGuess{value: MIN_STAKE}(puzzleId, 50);
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
