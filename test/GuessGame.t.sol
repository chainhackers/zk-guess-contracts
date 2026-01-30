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
    address treasury;

    function setUp() public {
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        guesser2 = makeAddr("guesser2");
        anyone = makeAddr("anyone");
        treasury = makeAddr("treasury");

        vm.deal(creator, 10 ether);
        vm.deal(guesser, 10 ether);
        vm.deal(guesser2, 10 ether);
        vm.deal(anyone, 10 ether);

        // Deploy verifier first
        verifier = new Groth16Verifier();
        // Deploy game with verifier address and treasury
        game = new GuessGame(address(verifier), treasury);
    }

    function test_CreatePuzzle() public {
        vm.startPrank(creator);

        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123))); // number=42, salt=123
        uint256 stakeRequired = 0.01 ether;

        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(commitment, stakeRequired, 100);

        assertEq(puzzleId, 0);
        assertEq(game.puzzleCount(), 1);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.creator, creator);
        assertEq(puzzle.commitment, commitment);
        assertEq(puzzle.bounty, 0.1 ether);
        assertEq(puzzle.collateral, 0.1 ether);
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

        // Now requires 2x MIN_BOUNTY (0.002 ether), so 0.001 ether is insufficient
        vm.expectRevert(IGuessGame.InsufficientBounty.selector);
        game.createPuzzle{value: 0.001 ether}(commitment, 0.01 ether, 100);

        vm.stopPrank();
    }

    function test_SubmitGuess() public {
        // First create a puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(
            keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.01 ether, 100
        );

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(
            keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.01 ether, 100
        );

        vm.startPrank(guesser);

        vm.expectRevert(IGuessGame.InsufficientStake.selector);
        game.submitGuess{value: 0.005 ether}(puzzleId, 50);

        vm.stopPrank();
    }

    function test_SubmitGuess_PuzzleCancelled() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(
            keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.01 ether, 100
        );

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(
            keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.01 ether, 100
        );

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Try to respond as non-creator
        vm.startPrank(guesser);

        uint256[2] memory pA = [uint256(0), uint256(0)];
        uint256[2][2] memory pB = [[uint256(0), uint256(0)], [uint256(0), uint256(0)]];
        uint256[2] memory pC = [uint256(0), uint256(0)];
        uint256[4] memory pubSignals = [uint256(0), uint256(0), uint256(0), uint256(0)];

        vm.expectRevert(IGuessGame.OnlyPuzzleCreator.selector);
        game.respondToChallenge(puzzleId, challengeId, pA, pB, pC, pubSignals);

        vm.stopPrank();
    }

    function test_CancelPuzzle() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        // Check creator balance before cancelling
        uint256 creatorBalanceBefore = creator.balance;

        // Cancel puzzle as creator
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        // Creator should receive bounty + collateral back (0.2 ether total)
        assertEq(creator.balance, creatorBalanceBefore + 0.2 ether);

        // Verify puzzle is cancelled
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.cancelled, true);
    }

    function test_CancelPuzzle_HasPendingChallenges() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        // Try to cancel as non-creator
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.OnlyPuzzleCreator.selector);
        game.cancelPuzzle(puzzleId);
    }

    function test_CancelPuzzle_NoChallenges_ImmediateCancel() public {
        // Create puzzle with no challenges - should be able to cancel immediately
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        uint256 creatorBalanceBefore = creator.balance;

        // Can cancel immediately when no challenges have been submitted
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        // Gets bounty + collateral back
        assertEq(creator.balance, creatorBalanceBefore + 0.2 ether);
    }

    function test_CancelPuzzle_CancelTooSoon() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        // Submit a guess with 0.01 ether stake
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, 0);

        // Claim from forfeited (single call per guesser)
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        // Balance should be credited: stake (0.01) + bounty share (0.1 / 1 = 0.1) = 0.11 ether
        assertEq(game.balances(guesser), 0.11 ether);

        // Withdraw to receive ETH
        uint256 guesserBalanceBefore = guesser.balance;
        vm.prank(guesser);
        game.withdraw();

        assertEq(guesser.balance, guesserBalanceBefore + 0.11 ether);
        assertEq(game.balances(guesser), 0);
    }

    function test_ClaimFromForfeited_MultipleGuessers() public {
        // Create puzzle with 0.1 ether bounty
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        // Two guessers submit
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        vm.prank(guesser2);
        game.submitGuess{value: 0.02 ether}(puzzleId, 99);

        // Warp and forfeit using first challenge
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, 0);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingAtForfeit, 2);

        // Both claim (single call per guesser)
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId);

        // Each gets stake + bounty share (0.1 * 1 / 2 = 0.05 ether per challenge)
        assertEq(game.balances(guesser), 0.01 ether + 0.05 ether);
        assertEq(game.balances(guesser2), 0.02 ether + 0.05 ether);

        // Withdraw
        uint256 guesser1BalanceBefore = guesser.balance;
        uint256 guesser2BalanceBefore = guesser2.balance;

        vm.prank(guesser);
        game.withdraw();
        vm.prank(guesser2);
        game.withdraw();

        assertEq(guesser.balance, guesser1BalanceBefore + 0.06 ether);
        assertEq(guesser2.balance, guesser2BalanceBefore + 0.07 ether);
    }

    function test_ClaimFromForfeited_NothingToClaim() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        // Guesser submits
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, 0);

        // guesser2 tries to claim but has no challenges
        vm.prank(guesser2);
        vm.expectRevert(IGuessGame.NothingToClaim.selector);
        game.claimFromForfeited(puzzleId);
    }

    function test_ClaimFromForfeited_DoubleClaim() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        // Submit guess
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, 0);

        // Claim once
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        // Try to claim again
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.AlreadyClaimed.selector);
        game.claimFromForfeited(puzzleId);
    }

    function test_ClaimFromForfeited_PuzzleNotForfeited() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        // Submit guess
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Try to claim without forfeit
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.PuzzleNotForfeited.selector);
        game.claimFromForfeited(puzzleId);
    }

    // ============ Collateral Tests ============

    function test_CreatePuzzleWithCollateral() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);

        // Verify 1:1 split
        assertEq(puzzle.bounty, 0.1 ether);
        assertEq(puzzle.collateral, 0.1 ether);
    }

    function test_CreatePuzzleWithOddAmount() public {
        // Test odd amount - extra wei should go to bounty
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.201 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);

        // collateral = 0.201 / 2 = 0.1005 ether
        // bounty = 0.201 - 0.1005 = 0.1005 ether
        assertEq(puzzle.collateral, 0.1005 ether);
        assertEq(puzzle.bounty, 0.1005 ether);
    }

    function test_CannotSubmitDuplicateGuess() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        // First guess succeeds
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Same guess from different guesser should fail
        vm.prank(guesser2);
        vm.expectRevert(IGuessGame.GuessAlreadySubmitted.selector);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Same guesser with same guess should also fail
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.GuessAlreadySubmitted.selector);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);
    }

    function test_CanSubmitDifferentGuesses() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        // Different guesses should succeed
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId, 43);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 44);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.challengeCount, 3);
        assertEq(puzzle.pendingChallenges, 3);
    }

    function test_CancelReturnsCollateral() public {
        uint256 creatorBalanceBefore = creator.balance;

        // Create puzzle with 0.2 ether (0.1 bounty + 0.1 collateral)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        assertEq(creator.balance, creatorBalanceBefore - 0.2 ether);

        // Cancel puzzle
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        // Creator gets bounty + collateral back (0.2 ether total)
        assertEq(creator.balance, creatorBalanceBefore);
    }

    function test_ForfeitSlashesCollateralToTreasury() public {
        uint256 treasuryBalanceBefore = treasury.balance;

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        // Submit a guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp time and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Treasury should receive collateral (0.1 ether)
        assertEq(treasury.balance, treasuryBalanceBefore + 0.1 ether);
    }

    function test_ForfeitEmitsCollateralSlashedEvent() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);

        vm.expectEmit(true, false, false, true);
        emit IGuessGame.CollateralSlashed(puzzleId, 0.1 ether);

        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);
    }

    function test_ForfeitRevertsIfTreasuryRejects() public {
        // Deploy game with reverting treasury
        RejectingReceiver badTreasury = new RejectingReceiver();
        GuessGame gameWithBadTreasury = new GuessGame(address(verifier), address(badTreasury));

        vm.prank(creator);
        uint256 puzzleId = gameWithBadTreasury.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = gameWithBadTreasury.submitGuess{value: 0.01 ether}(puzzleId, 42);

        vm.warp(block.timestamp + gameWithBadTreasury.RESPONSE_TIMEOUT() + 1);

        vm.expectRevert(IGuessGame.TransferFailed.selector);
        vm.prank(anyone);
        gameWithBadTreasury.forfeitPuzzle(puzzleId, challengeId);
    }

    function test_MultiplePuzzlesForfeit_CollateralIsolated() public {
        uint256 treasuryBalanceBefore = treasury.balance;

        // Create 3 puzzles with different bounties
        vm.prank(creator);
        uint256 puzzle1 = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100); // 0.1 collateral
        vm.prank(creator);
        uint256 puzzle2 = game.createPuzzle{value: 0.4 ether}(bytes32(uint256(2)), 0.01 ether, 100); // 0.2 collateral
        vm.prank(creator);
        uint256 puzzle3 = game.createPuzzle{value: 0.6 ether}(bytes32(uint256(3)), 0.01 ether, 100); // 0.3 collateral

        // Submit guesses to all 3
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzle1, 10);
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzle2, 20);
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzle3, 30);

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);

        // Forfeit only puzzle2
        vm.prank(anyone);
        game.forfeitPuzzle(puzzle2, 0);

        // Treasury gets exactly puzzle2's collateral (0.2 ether)
        assertEq(treasury.balance, treasuryBalanceBefore + 0.2 ether);

        // Puzzle1 and puzzle3 collateral unchanged
        assertEq(game.getPuzzle(puzzle1).collateral, 0.1 ether);
        assertEq(game.getPuzzle(puzzle3).collateral, 0.3 ether);
        assertFalse(game.getPuzzle(puzzle1).forfeited);
        assertFalse(game.getPuzzle(puzzle3).forfeited);
    }

    function test_CancelDoesNotSlashCollateral() public {
        uint256 treasuryBefore = treasury.balance;

        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.01 ether, 100);

        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        assertEq(treasury.balance, treasuryBefore);
    }
}

contract RejectingReceiver {
    receive() external payable {
        revert("rejected");
    }
}
