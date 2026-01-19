// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/GuessGame.sol";
import "../src/generated/GuessVerifier.sol";

contract GuessGameTest is Test {
    Groth16Verifier public verifier;
    GuessGame public game;

    address creator;
    address guesser;
    address guesser2;
    address anyone;

    function setUp() public {
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        guesser2 = makeAddr("guesser2");
        anyone = makeAddr("anyone");

        vm.deal(creator, 10 ether);
        vm.deal(guesser, 10 ether);
        vm.deal(guesser2, 10 ether);
        vm.deal(anyone, 10 ether);

        // Deploy verifier first
        verifier = new Groth16Verifier();
        // Deploy game with verifier address
        game = new GuessGame(address(verifier));
    }

    function test_CreatePuzzle() public {
        vm.startPrank(creator);

        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123))); // number=42, salt=123
        uint256 stakeRequired = 0.01 ether;

        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(commitment, stakeRequired);

        assertEq(puzzleId, 0);
        assertEq(game.puzzleCount(), 1);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.creator, creator);
        assertEq(puzzle.commitment, commitment);
        assertEq(puzzle.bounty, 0.1 ether);
        assertEq(puzzle.stakeRequired, stakeRequired);
        assertEq(puzzle.solved, false);
        assertEq(puzzle.cancelled, false);
        assertEq(puzzle.forfeited, false);
        assertEq(puzzle.challengeCount, 0);
        assertEq(puzzle.pendingChallenges, 0);
        assertEq(puzzle.lastChallengeTimestamp, 0);
        assertEq(puzzle.pendingAtForfeit, 0);

        vm.stopPrank();
    }

    function test_CreatePuzzle_InsufficientBounty() public {
        vm.startPrank(creator);

        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));

        vm.expectRevert(IGuessGame.InsufficientBounty.selector);
        game.createPuzzle{value: 0.0001 ether}(commitment, 0.01 ether);

        vm.stopPrank();
    }

    function test_SubmitGuess() public {
        // First create a puzzle
        vm.prank(creator);
        uint256 puzzleId =
            game.createPuzzle{value: 0.1 ether}(keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.01 ether);

        // Submit a guess
        vm.startPrank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        assertEq(challengeId, 0);

        IGuessGame.Challenge memory challenge = game.getChallenge(puzzleId, challengeId);
        assertEq(challenge.guesser, guesser);
        assertEq(challenge.guess, 50);
        assertEq(challenge.stake, 0.01 ether);
        assertEq(challenge.responded, false);

        // Check puzzle was updated
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.challengeCount, 1);
        assertEq(puzzle.pendingChallenges, 1);
        assertEq(puzzle.lastChallengeTimestamp, block.timestamp);

        vm.stopPrank();
    }

    function test_SubmitGuess_PuzzleNotFound() public {
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.PuzzleNotFound.selector);
        game.submitGuess{value: 0.01 ether}(999, 50);
    }

    function test_SubmitGuess_InsufficientStake() public {
        // Create puzzle with 0.01 ether stake requirement
        vm.prank(creator);
        uint256 puzzleId =
            game.createPuzzle{value: 0.1 ether}(keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.01 ether);

        vm.startPrank(guesser);

        vm.expectRevert(IGuessGame.InsufficientStake.selector);
        game.submitGuess{value: 0.005 ether}(puzzleId, 50);

        vm.stopPrank();
    }

    function test_SubmitGuess_PuzzleCancelled() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId =
            game.createPuzzle{value: 0.1 ether}(keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.01 ether);

        // Cancel it
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        // Try to guess on cancelled puzzle
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.PuzzleCancelledError.selector);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);
    }

    // Note: Testing respondToChallenge requires valid ZK proofs
    // which would be generated off-chain. For unit tests, we can
    // test the access control and state transitions with mock proofs
    // that will fail verification.

    function test_RespondToChallenge_OnlyCreator() public {
        // Create puzzle and submit guess
        vm.prank(creator);
        uint256 puzzleId =
            game.createPuzzle{value: 0.1 ether}(keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.01 ether);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Try to respond as non-creator
        vm.startPrank(guesser);

        uint256[2] memory pA = [uint256(0), uint256(0)];
        uint256[2][2] memory pB = [[uint256(0), uint256(0)], [uint256(0), uint256(0)]];
        uint256[2] memory pC = [uint256(0), uint256(0)];
        uint256[2] memory pubSignals = [uint256(0), uint256(0)];

        vm.expectRevert(IGuessGame.OnlyPuzzleCreator.selector);
        game.respondToChallenge(puzzleId, challengeId, pA, pB, pC, pubSignals);

        vm.stopPrank();
    }

    function test_CancelPuzzle() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Check creator balance before cancelling
        uint256 creatorBalanceBefore = creator.balance;

        // Cancel puzzle as creator
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        // Creator should receive bounty back
        assertEq(creator.balance, creatorBalanceBefore + 0.1 ether);

        // Verify puzzle is cancelled
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.cancelled, true);
    }

    function test_CancelPuzzle_HasPendingChallenges() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Submit a guess
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Try to cancel - should fail due to pending challenges
        vm.prank(creator);
        vm.expectRevert(IGuessGame.HasPendingChallenges.selector);
        game.cancelPuzzle(puzzleId);
    }

    function test_CancelPuzzle_OnlyCreator() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Try to cancel as non-creator
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.OnlyPuzzleCreator.selector);
        game.cancelPuzzle(puzzleId);
    }

    function test_CancelPuzzle_NoChallenges_ImmediateCancel() public {
        // Create puzzle with no challenges - should be able to cancel immediately
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        uint256 creatorBalanceBefore = creator.balance;

        // Can cancel immediately when no challenges have been submitted
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        assertEq(creator.balance, creatorBalanceBefore + 0.1 ether);
    }

    function test_CancelPuzzle_CancelTooSoon() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Submit a guess (creates lastChallengeTimestamp)
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp time but not enough (less than CANCEL_TIMEOUT)
        vm.warp(block.timestamp + 12 hours);

        // Trying to cancel should fail - still has pending challenge
        vm.prank(creator);
        vm.expectRevert(IGuessGame.HasPendingChallenges.selector);
        game.cancelPuzzle(puzzleId);
    }

    function test_CancelPuzzle_AfterTimeout() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Submit a guess
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp time past timeout but still have pending challenge - should fail
        vm.warp(block.timestamp + 2 days);

        // Still can't cancel because challenge is pending
        vm.prank(creator);
        vm.expectRevert(IGuessGame.HasPendingChallenges.selector);
        game.cancelPuzzle(puzzleId);
    }

    function test_CancelTimeout_Constant() public view {
        // Verify the timeout constant is 1 day
        assertEq(game.CANCEL_TIMEOUT(), 1 days);
    }

    function test_ResponseTimeout_Constant() public view {
        // Verify the response timeout constant is 1 day
        assertEq(game.RESPONSE_TIMEOUT(), 1 days);
    }

    // ============ Forfeit Tests ============

    function test_ForfeitPuzzle_Success() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Submit a guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp time past response timeout
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);

        // Anyone can forfeit
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Verify puzzle is forfeited
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.forfeited, true);
        assertEq(puzzle.pendingAtForfeit, 1);
    }

    function test_ForfeitPuzzle_TooEarly() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Submit a guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp time but not enough
        vm.warp(block.timestamp + 12 hours);

        // Try to forfeit - should fail
        vm.prank(anyone);
        vm.expectRevert(IGuessGame.NoTimedOutChallenge.selector);
        game.forfeitPuzzle(puzzleId, challengeId);
    }

    function test_ForfeitPuzzle_ChallengeAlreadyResponded() public {
        // This test would require a valid proof to respond, so we skip it here
        // It's covered in GuessGameWithProofs.t.sol
    }

    function test_SubmitGuess_PuzzleForfeited() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Submit a guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Try to submit new guess - should fail
        vm.prank(guesser2);
        vm.expectRevert(IGuessGame.PuzzleForfeitedError.selector);
        game.submitGuess{value: 0.01 ether}(puzzleId, 99);
    }

    function test_CancelPuzzle_PuzzleForfeited() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Submit a guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Try to cancel - should fail
        vm.prank(creator);
        vm.expectRevert(IGuessGame.PuzzleForfeitedError.selector);
        game.cancelPuzzle(puzzleId);
    }

    function test_ClaimFromForfeited_Success() public {
        // Create puzzle with 0.1 ether bounty
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Submit a guess with 0.01 ether stake
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        uint256 guesserBalanceBefore = guesser.balance;

        // Claim from forfeited
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId, challengeId);

        // Guesser should receive stake (0.01) + bounty share (0.1 / 1 = 0.1) = 0.11 ether
        assertEq(guesser.balance, guesserBalanceBefore + 0.11 ether);

        // Challenge should be marked as responded
        IGuessGame.Challenge memory challenge = game.getChallenge(puzzleId, challengeId);
        assertEq(challenge.responded, true);

        // Pending challenges should be decremented
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingChallenges, 0);
    }

    function test_ClaimFromForfeited_MultipleGuessers() public {
        // Create puzzle with 0.1 ether bounty
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Two guessers submit
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.02 ether}(puzzleId, 99);

        // Warp and forfeit using first challenge
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId1);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingAtForfeit, 2);

        uint256 guesser1BalanceBefore = guesser.balance;
        uint256 guesser2BalanceBefore = guesser2.balance;

        // Both claim
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId, challengeId1);

        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId, challengeId2);

        // Each gets stake + 0.1/2 = stake + 0.05 ether bounty share
        assertEq(guesser.balance, guesser1BalanceBefore + 0.01 ether + 0.05 ether);
        assertEq(guesser2.balance, guesser2BalanceBefore + 0.02 ether + 0.05 ether);
    }

    function test_ClaimFromForfeited_NotYourChallenge() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Guesser submits
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        // guesser2 tries to claim guesser's challenge
        vm.prank(guesser2);
        vm.expectRevert(IGuessGame.NotYourChallenge.selector);
        game.claimFromForfeited(puzzleId, challengeId);
    }

    function test_ClaimFromForfeited_DoubleClaim() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Claim once
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId, challengeId);

        // Try to claim again
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.ChallengeAlreadyResponded.selector);
        game.claimFromForfeited(puzzleId, challengeId);
    }

    function test_ClaimFromForfeited_PuzzleNotForfeited() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(bytes32(uint256(1)), 0.01 ether);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Try to claim without forfeit
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.PuzzleNotForfeited.selector);
        game.claimFromForfeited(puzzleId, challengeId);
    }
}
