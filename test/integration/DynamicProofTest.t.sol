// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/GuessGame.sol";
import "../../src/generated/GuessVerifier.sol";
import "../utils/ProofGenerator.sol";

/**
 * @title DynamicProofTest
 * @notice SLOW integration tests using FFI-based ZK proof generation
 * @dev These tests generate proofs at runtime via FFI, verifying the full proof flow
 *      with truly dynamic values.
 *
 * WARNING: These tests are SLOW (~90-120 seconds per test due to proof generation).
 *          They are excluded from normal test runs.
 *
 * Circuit constraints: secret must be 1-65535 (enforced by GuessNumber circuit)
 *
 * Run these tests separately:
 *   forge test --match-path "test/integration/*" -vvv --ffi
 *
 * Run ALL tests (including slow integration tests):
 *   forge test --ffi
 *
 * Run fast tests only (excludes integration):
 *   forge test --no-match-path "test/integration/*"
 */
contract DynamicProofTest is Test, ProofGenerator {
    Groth16Verifier public verifier;
    GuessGame public game;

    address creator;
    address guesser;
    address treasury;

    function setUp() public {
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        treasury = makeAddr("treasury");

        vm.deal(creator, 10 ether);
        vm.deal(guesser, 10 ether);

        verifier = new Groth16Verifier();
        game = new GuessGame(address(verifier), treasury);
    }

    /**
     * @notice Full game flow with dynamically generated proof - correct guess
     * @dev Tests: Create puzzle -> Submit correct guess -> Respond with FFI proof -> Verify win
     */
    function test_DynamicProof_CorrectGuess() public {
        uint256 secret = 42;
        uint256 salt = 123;
        uint256 guess = 42; // correct guess

        // Generate commitment using FFI
        bytes32 commitment = computeCommitment(secret, salt);

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(commitment, 0.01 ether, 65535);

        // Submit correct guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, guess);

        uint256 guesserBalanceBefore = guesser.balance;

        // Generate proof dynamically via FFI
        (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory pubSignals) =
            generateProof(secret, salt, guess);

        // Verify pubSignals are correct
        assertEq(pubSignals[1], 1, "isCorrect should be 1 for correct guess");
        assertEq(pubSignals[2], guess, "guess in pubSignals should match");

        // Respond with proof
        vm.prank(creator);
        game.respondToChallenge(puzzleId, challengeId, pA, pB, pC, pubSignals);

        // Verify puzzle is solved
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertTrue(puzzle.solved, "Puzzle should be solved");

        // Verify winner received bounty + stake
        uint256 expectedPrize = 0.1 ether + 0.01 ether;
        assertEq(guesser.balance, guesserBalanceBefore + expectedPrize, "Winner should receive bounty + stake");
    }

    /**
     * @notice Incorrect guess flow with dynamic proof
     * @dev Tests: Create puzzle -> Submit wrong guess -> Respond with FFI proof -> Verify refund
     */
    function test_DynamicProof_IncorrectGuess() public {
        uint256 secret = 42;
        uint256 salt = 123;
        uint256 guess = 99; // incorrect guess

        // Generate commitment using FFI
        bytes32 commitment = computeCommitment(secret, salt);

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(commitment, 0.01 ether, 65535);

        // Submit incorrect guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, guess);

        uint256 guesserBalanceBefore = guesser.balance;

        // Generate proof dynamically via FFI
        (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory pubSignals) =
            generateProof(secret, salt, guess);

        // Verify pubSignals are correct
        assertEq(pubSignals[1], 0, "isCorrect should be 0 for incorrect guess");
        assertEq(pubSignals[2], guess, "guess in pubSignals should match");

        // Respond with proof
        vm.prank(creator);
        game.respondToChallenge(puzzleId, challengeId, pA, pB, pC, pubSignals);

        // Verify puzzle is NOT solved
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertFalse(puzzle.solved, "Puzzle should not be solved");

        // Verify guesser got stake back
        assertEq(guesser.balance, guesserBalanceBefore + 0.01 ether, "Guesser should get stake back");
    }

    /**
     * @notice Test with non-hardcoded values
     * @dev Uses different values than hardcoded tests to ensure circuit works generally
     * @dev Circuit constrains: secret must be 1-65535 (16-bit range)
     */
    function test_DynamicProof_DifferentValues() public {
        // Use non-trivial values within circuit constraints (secret: 1-65535)
        uint256 secret = 73;
        uint256 salt = 456;
        uint256 wrongGuess = (secret % 65535) + 1; // guaranteed to be different (74)

        // Generate commitment using FFI
        bytes32 commitment = computeCommitment(secret, salt);

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(commitment, 0.01 ether, 65535);

        // Submit wrong guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, wrongGuess);

        // Generate proof for wrong guess
        (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory pubSignals) =
            generateProof(secret, salt, wrongGuess);

        // Verify pubSignals
        assertEq(pubSignals[1], 0, "isCorrect should be 0");
        assertEq(pubSignals[2], wrongGuess, "guess should match");

        // Respond with proof
        vm.prank(creator);
        game.respondToChallenge(puzzleId, challengeId, pA, pB, pC, pubSignals);

        // Puzzle not solved
        assertFalse(game.getPuzzle(puzzleId).solved, "Puzzle should not be solved");

        // Now submit the correct guess
        vm.prank(guesser);
        uint256 correctChallengeId = game.submitGuess{value: 0.01 ether}(puzzleId, secret);

        // Generate proof for correct guess
        (pA, pB, pC, pubSignals) = generateProof(secret, salt, secret);

        assertEq(pubSignals[1], 1, "isCorrect should be 1");

        // Respond with correct proof
        vm.prank(creator);
        game.respondToChallenge(puzzleId, correctChallengeId, pA, pB, pC, pubSignals);

        // Now puzzle should be solved
        assertTrue(game.getPuzzle(puzzleId).solved, "Puzzle should be solved");
    }

    /**
     * @notice Complete flow: multiple guesses with dynamic proofs
     * @dev Tests multiple guessers, wrong guesses, then correct guess wins
     * @dev Circuit constrains: secret must be 1-65535
     */
    function test_DynamicProof_MultipleGuessers() public {
        uint256 secret = 77;
        uint256 salt = 888;

        address guesser2 = makeAddr("guesser2");
        vm.deal(guesser2, 10 ether);

        // Generate commitment
        bytes32 commitment = computeCommitment(secret, salt);

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(commitment, 0.01 ether, 65535);

        // Guesser 1 submits wrong guess
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 100);

        // Guesser 2 submits correct guess
        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.01 ether}(puzzleId, secret);

        uint256 guesser2BalanceBefore = guesser2.balance;

        // Respond to wrong guess first
        {
            (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory pubSignals) =
                generateProof(secret, salt, 100);

            vm.prank(creator);
            game.respondToChallenge(puzzleId, challengeId1, pA, pB, pC, pubSignals);
        }

        // Puzzle not solved yet
        assertFalse(game.getPuzzle(puzzleId).solved, "Puzzle should not be solved yet");

        // Respond to correct guess
        {
            (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory pubSignals) =
                generateProof(secret, salt, secret);

            vm.prank(creator);
            game.respondToChallenge(puzzleId, challengeId2, pA, pB, pC, pubSignals);
        }

        // Puzzle solved
        assertTrue(game.getPuzzle(puzzleId).solved, "Puzzle should be solved");

        // Guesser2 wins bounty + stake
        uint256 expectedPrize = 0.1 ether + 0.01 ether;
        assertEq(guesser2.balance, guesser2BalanceBefore + expectedPrize, "Winner should receive bounty + stake");
    }

    /**
     * @notice Fuzz test with random large numbers in 16-bit range
     * @dev Uses fuzz parameters to test with different random values each CI run
     */
    function testFuzz_DynamicProof_RandomLargeNumbers(uint256 secretSeed, uint256 saltSeed, uint256 guessSeed) public {
        // Bound values to 16-bit range (1-65535)
        uint256 secret = bound(secretSeed, 1, 65535);
        uint256 salt = saltSeed;
        uint256 wrongGuess = bound(guessSeed, 1, 65535);

        // Ensure wrong guess is different from secret
        if (wrongGuess == secret) {
            wrongGuess = (wrongGuess % 65534) + 1;
            if (wrongGuess >= secret) wrongGuess++;
        }

        // Generate commitment using FFI
        bytes32 commitment = computeCommitment(secret, salt);

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(commitment, 0.01 ether, 65535);

        // Submit wrong guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, wrongGuess);

        // Generate proof for wrong guess
        (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory pubSignals) =
            generateProof(secret, salt, wrongGuess);

        assertEq(pubSignals[1], 0, "isCorrect should be 0");

        // Respond with proof
        vm.prank(creator);
        game.respondToChallenge(puzzleId, challengeId, pA, pB, pC, pubSignals);

        assertFalse(game.getPuzzle(puzzleId).solved, "Puzzle should not be solved");

        // Submit correct guess
        vm.prank(guesser);
        uint256 correctChallengeId = game.submitGuess{value: 0.01 ether}(puzzleId, secret);

        // Generate proof for correct guess
        (pA, pB, pC, pubSignals) = generateProof(secret, salt, secret);

        assertEq(pubSignals[1], 1, "isCorrect should be 1");

        // Respond with correct proof
        vm.prank(creator);
        game.respondToChallenge(puzzleId, correctChallengeId, pA, pB, pC, pubSignals);

        assertTrue(game.getPuzzle(puzzleId).solved, "Puzzle should be solved");
    }

    /**
     * @notice Verify commitment matches between FFI and contract
     * @dev Sanity check that the commitment from FFI matches what the contract stores
     * @dev Circuit constrains: secret must be 1-65535
     */
    function test_DynamicProof_CommitmentIntegrity() public {
        uint256 secret = 55;
        uint256 salt = 678;

        // Generate commitment via FFI
        bytes32 commitment = computeCommitment(secret, salt);

        // Create puzzle with this commitment
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(commitment, 0.01 ether, 65535);

        // Verify stored commitment matches
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.commitment, commitment, "Stored commitment should match FFI-generated one");

        // Generate a proof and verify the commitment in pubSignals matches
        (,,, uint256[4] memory pubSignals) = generateProof(secret, salt, secret);

        assertEq(bytes32(pubSignals[0]), commitment, "Proof commitment should match puzzle commitment");
    }
}
