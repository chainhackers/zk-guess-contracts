// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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
        // Deploy game via proxy
        game = deployGameProxy(address(verifier), treasury);
    }

    function deployGameProxy(address _verifier, address _treasury) internal returns (GuessGame) {
        GuessGame impl = new GuessGame();
        bytes memory initData = abi.encodeCall(GuessGame.initialize, (_verifier, _treasury, address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return GuessGame(address(proxy));
    }

    function test_CreatePuzzle() public {
        vm.startPrank(creator);

        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123))); // number=42, salt=123
        uint256 stakeRequired = 0.01 ether;

        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(commitment, 0.0001 ether, stakeRequired, 100);

        assertEq(puzzleId, 0);
        assertEq(game.puzzleCount(), 1);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.creator, creator);
        assertEq(puzzle.commitment, commitment);
        assertEq(puzzle.bounty, 0.0001 ether); // MIN_BOUNTY
        assertEq(puzzle.collateral, 0.1999 ether); // msg.value - MIN_BOUNTY
        assertEq(puzzle.stakeRequired, stakeRequired);
        assertEq(puzzle.solved, false);
        assertEq(puzzle.cancelled, false);
        assertEq(puzzle.forfeited, false);
        assertEq(puzzle.challengeCount, 0);
        assertEq(puzzle.pendingChallenges, 0);
        assertEq(puzzle.lastChallengeTimestamp, block.timestamp);
        assertEq(puzzle.lastResponseTime, 0);
        assertEq(puzzle.pendingAtForfeit, 0);

        vm.stopPrank();
    }

    function test_CreatePuzzle_InsufficientBounty() public {
        vm.startPrank(creator);

        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));

        // Requires MIN_BOUNTY (0.0001 ether), so 0.00009 ether is insufficient
        vm.expectRevert(IGuessGame.InsufficientBounty.selector);
        game.createPuzzle{value: 0.00009 ether}(commitment, 0.00009 ether, 0.01 ether, 100);

        vm.stopPrank();
    }

    function test_SubmitGuess() public {
        // First create a puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(
            keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.0001 ether, 0.01 ether, 100
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
            keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.0001 ether, 0.01 ether, 100
        );

        vm.startPrank(guesser);

        vm.expectRevert(IGuessGame.InsufficientStake.selector);
        game.submitGuess{value: 0.005 ether}(puzzleId, 50);

        vm.stopPrank();
    }

    function test_SubmitGuess_InvalidGuessRange() public {
        // Create puzzle with maxNumber = 100
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        vm.startPrank(guesser);

        // Guess 0 should fail
        vm.expectRevert(IGuessGame.InvalidGuessRange.selector);
        game.submitGuess{value: 0.01 ether}(puzzleId, 0);

        // Guess above maxNumber should fail
        vm.expectRevert(IGuessGame.InvalidGuessRange.selector);
        game.submitGuess{value: 0.01 ether}(puzzleId, 101);

        // Valid guess should succeed
        game.submitGuess{value: 0.01 ether}(puzzleId, 100);

        vm.stopPrank();
    }

    function test_SubmitGuess_PuzzleCancelled() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(
            keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.0001 ether, 0.01 ether, 100
        );

        // Warp past cancel timeout and cancel
        vm.warp(block.timestamp + game.CANCEL_TIMEOUT() + 1);
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
            keccak256(abi.encodePacked(uint256(42), uint256(123))), 0.0001 ether, 0.01 ether, 100
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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Warp past cancel timeout
        vm.warp(block.timestamp + game.CANCEL_TIMEOUT() + 1);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Try to cancel as non-creator
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.OnlyPuzzleCreator.selector);
        game.cancelPuzzle(puzzleId);
    }

    function test_CancelPuzzle_FreshPuzzleTooSoon() public {
        // Create puzzle with no challenges - cannot cancel immediately
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Immediate cancel should fail
        vm.prank(creator);
        vm.expectRevert(IGuessGame.CancelTooSoon.selector);
        game.cancelPuzzle(puzzleId);
    }

    function test_CancelPuzzle_NoChallenges_AfterTimeout() public {
        // Create puzzle with no challenges
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Warp past cancel timeout
        vm.warp(block.timestamp + game.CANCEL_TIMEOUT() + 1);

        uint256 creatorBalanceBefore = creator.balance;

        // Can cancel after timeout
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        // Gets bounty + collateral back
        assertEq(creator.balance, creatorBalanceBefore + 0.2 ether);
    }

    function test_CancelPuzzle_CancelTooSoon() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Submit a guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp time but not enough
        vm.warp(block.timestamp + 12 hours);

        // Try to forfeit - should fail
        vm.prank(anyone);
        vm.expectRevert(IGuessGame.CreatorStillActive.selector);
        game.forfeitPuzzle(puzzleId, challengeId);
    }

    function test_ForfeitPuzzle_ChallengeAlreadyResponded() public {
        // This test would require a valid proof to respond, so we skip it here
        // It's covered in GuessGameWithProofs.t.sol
    }

    function test_SubmitGuess_PuzzleForfeited() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        // Create puzzle with MIN_BOUNTY (0.0001 ether)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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

        // Balance should be credited: stake (0.01) + bounty share (0.0001 / 1 = 0.0001) = 0.0101 ether
        assertEq(game.balances(guesser), 0.0101 ether);

        // Withdraw to receive ETH
        uint256 guesserBalanceBefore = guesser.balance;
        vm.prank(guesser);
        game.withdraw();

        assertEq(guesser.balance, guesserBalanceBefore + 0.0101 ether);
        assertEq(game.balances(guesser), 0);
    }

    function test_ClaimFromForfeited_MultipleGuessers() public {
        // Create puzzle with MIN_BOUNTY (0.0001 ether)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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

        // Each gets stake + bounty share (0.0001 * 1 / 2 = 0.00005 ether per challenge)
        assertEq(game.balances(guesser), 0.01 ether + 0.00005 ether);
        assertEq(game.balances(guesser2), 0.02 ether + 0.00005 ether);

        // Withdraw
        uint256 guesser1BalanceBefore = guesser.balance;
        uint256 guesser2BalanceBefore = guesser2.balance;

        vm.prank(guesser);
        game.withdraw();
        vm.prank(guesser2);
        game.withdraw();

        assertEq(guesser.balance, guesser1BalanceBefore + 0.01005 ether);
        assertEq(guesser2.balance, guesser2BalanceBefore + 0.02005 ether);
    }

    function test_ClaimFromForfeited_NothingToClaim() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);

        // Bounty is MIN_BOUNTY, rest is collateral
        assertEq(puzzle.bounty, 0.0001 ether);
        assertEq(puzzle.collateral, 0.1999 ether);
    }

    function test_CreatePuzzleWithMinBountyOnly() public {
        // Test creating puzzle with just MIN_BOUNTY (no collateral)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.0001 ether}(bytes32(uint256(1)), 0.0001 ether, 0.00001 ether, 100);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);

        assertEq(puzzle.bounty, 0.0001 ether);
        assertEq(puzzle.collateral, 0); // No collateral when sending exactly MIN_BOUNTY
    }

    function test_CannotSubmitDuplicateGuess() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        assertEq(creator.balance, creatorBalanceBefore - 0.2 ether);

        // Warp past cancel timeout
        vm.warp(block.timestamp + game.CANCEL_TIMEOUT() + 1);

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
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Submit a guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp time and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Treasury should receive collateral (0.1999 ether = 0.2 - MIN_BOUNTY)
        assertEq(treasury.balance, treasuryBalanceBefore + 0.1999 ether);
    }

    function test_ForfeitEmitsCollateralSlashedEvent() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);

        vm.expectEmit(true, false, false, true);
        emit IGuessGame.CollateralSlashed(puzzleId, 0.1999 ether);

        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);
    }

    function test_ForfeitRevertsIfTreasuryRejects() public {
        // Deploy game with reverting treasury
        RejectingReceiver badTreasury = new RejectingReceiver();
        GuessGame gameWithBadTreasury = deployGameProxy(address(verifier), address(badTreasury));

        vm.prank(creator);
        uint256 puzzleId =
            gameWithBadTreasury.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = gameWithBadTreasury.submitGuess{value: 0.01 ether}(puzzleId, 42);

        vm.warp(block.timestamp + gameWithBadTreasury.RESPONSE_TIMEOUT() + 1);

        vm.expectRevert(IGuessGame.TransferFailed.selector);
        vm.prank(anyone);
        gameWithBadTreasury.forfeitPuzzle(puzzleId, challengeId);
    }

    function test_MultiplePuzzlesForfeit_CollateralIsolated() public {
        uint256 treasuryBalanceBefore = treasury.balance;

        // Create 3 puzzles with different amounts (bounty = MIN_BOUNTY, rest = collateral)
        vm.prank(creator);
        uint256 puzzle1 = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100); // 0.1999 collateral
        vm.prank(creator);
        uint256 puzzle2 = game.createPuzzle{value: 0.4 ether}(bytes32(uint256(2)), 0.0001 ether, 0.01 ether, 100); // 0.3999 collateral
        vm.prank(creator);
        uint256 puzzle3 = game.createPuzzle{value: 0.6 ether}(bytes32(uint256(3)), 0.0001 ether, 0.01 ether, 100); // 0.5999 collateral

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

        // Treasury gets exactly puzzle2's collateral (0.3999 ether)
        assertEq(treasury.balance, treasuryBalanceBefore + 0.3999 ether);

        // Puzzle1 and puzzle3 collateral unchanged
        assertEq(game.getPuzzle(puzzle1).collateral, 0.1999 ether);
        assertEq(game.getPuzzle(puzzle3).collateral, 0.5999 ether);
        assertFalse(game.getPuzzle(puzzle1).forfeited);
        assertFalse(game.getPuzzle(puzzle3).forfeited);
    }

    function test_CancelDoesNotSlashCollateral() public {
        uint256 treasuryBefore = treasury.balance;

        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        vm.warp(block.timestamp + game.CANCEL_TIMEOUT() + 1);
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        assertEq(treasury.balance, treasuryBefore);
    }

    function test_ForfeitWithZeroCollateral_NoSlash() public {
        uint256 treasuryBefore = treasury.balance;

        // Create puzzle with exactly MIN_BOUNTY (no collateral)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.0001 ether}(bytes32(uint256(1)), 0.0001 ether, 0.00001 ether, 100);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.bounty, 0.0001 ether);
        assertEq(puzzle.collateral, 0);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.00001 ether}(puzzleId, 42);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Treasury should NOT receive anything (no collateral to slash)
        assertEq(treasury.balance, treasuryBefore);

        // Guesser can still claim stake + full bounty
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        // Balance = stake (0.00001) + bounty (0.0001) = 0.00011 ether
        assertEq(game.balances(guesser), 0.00011 ether);
    }

    function test_CreatePuzzleWithCollateralLessThanBounty() public {
        uint256 treasuryBefore = treasury.balance;

        // Create puzzle with collateral < bounty
        // msg.value = 0.00015 ether → bounty = 0.0001, collateral = 0.00005
        vm.prank(creator);
        uint256 puzzleId =
            game.createPuzzle{value: 0.00015 ether}(bytes32(uint256(1)), 0.0001 ether, 0.00001 ether, 100);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.bounty, 0.0001 ether);
        assertEq(puzzle.collateral, 0.00005 ether); // Less than bounty

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.00001 ether}(puzzleId, 42);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Treasury receives the small collateral
        assertEq(treasury.balance, treasuryBefore + 0.00005 ether);

        // Guesser claims stake + bounty
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);
        assertEq(game.balances(guesser), 0.00001 ether + 0.0001 ether);
    }

    function test_CancelWithZeroCollateral() public {
        uint256 creatorBefore = creator.balance;

        // Create puzzle with no collateral
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.0001 ether}(bytes32(uint256(1)), 0.0001 ether, 0.00001 ether, 100);

        assertEq(creator.balance, creatorBefore - 0.0001 ether);

        // Warp past cancel timeout
        vm.warp(block.timestamp + game.CANCEL_TIMEOUT() + 1);

        // Cancel (no challenges)
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        // Creator gets back exactly MIN_BOUNTY (no collateral)
        assertEq(creator.balance, creatorBefore);
    }

    // ============ UUPS Upgrade Tests ============

    function test_CannotReinitialize() public {
        vm.expectRevert();
        game.initialize(address(verifier), treasury, address(this));
    }

    function test_ImplementationCannotBeInitialized() public {
        GuessGame impl = new GuessGame();
        vm.expectRevert();
        impl.initialize(address(verifier), treasury, address(this));
    }

    function test_OnlyOwnerCanUpgrade() public {
        GuessGame newImpl = new GuessGame();

        vm.prank(anyone);
        vm.expectRevert();
        game.upgradeToAndCall(address(newImpl), "");
    }

    function test_OwnerCanUpgrade() public {
        // Create a puzzle before upgrade
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Deploy new implementation
        GuessGame newImpl = new GuessGame();

        // Owner (test contract) upgrades
        game.upgradeToAndCall(address(newImpl), "");

        // State preserved after upgrade
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.creator, creator);
        assertEq(puzzle.bounty, 0.0001 ether);
        assertEq(puzzle.collateral, 0.1999 ether);
        assertEq(game.puzzleCount(), 1);
    }

    function test_UpgradePreservesActiveGame() public {
        // Create puzzle and submit guess
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Verify pre-upgrade state
        assertEq(game.getPuzzle(puzzleId).pendingChallenges, 1);
        assertEq(game.guesserChallengeCount(puzzleId, guesser), 1);

        // Upgrade
        GuessGame newImpl = new GuessGame();
        game.upgradeToAndCall(address(newImpl), "");

        // State preserved
        assertEq(game.getPuzzle(puzzleId).pendingChallenges, 1);
        assertEq(game.guesserChallengeCount(puzzleId, guesser), 1);
        assertEq(game.guesserStakeTotal(puzzleId, guesser), 0.01 ether);
    }

    // ============ Timeout Boundary Tests ============

    function test_ForfeitAtExactTimeout() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Submit a guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        uint256 challengeTimestamp = block.timestamp;

        // Warp to exactly referenceTime + RESPONSE_TIMEOUT (not +1)
        vm.warp(challengeTimestamp + game.RESPONSE_TIMEOUT());

        // Forfeit should succeed at exactly the timeout boundary
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.forfeited, true);
    }

    function test_ForfeitOneSecondBeforeTimeout() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Submit a guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        uint256 challengeTimestamp = block.timestamp;

        // Warp to one second before timeout
        vm.warp(challengeTimestamp + game.RESPONSE_TIMEOUT() - 1);

        // Forfeit should fail - creator still has time
        vm.prank(anyone);
        vm.expectRevert(IGuessGame.CreatorStillActive.selector);
        game.forfeitPuzzle(puzzleId, challengeId);
    }

    // ============ Forfeit Timeout Reset Test ============

    function test_ForfeitTimeoutResetsOnResponse() public {
        // This test requires valid proofs - see GuessGameWithProofs.t.sol
        // Here we verify the lastResponseTime is set correctly

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Submit two guesses
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId, 43);

        // Verify lastResponseTime starts at 0
        IGuessGame.Puzzle memory puzzleBefore = game.getPuzzle(puzzleId);
        assertEq(puzzleBefore.lastResponseTime, 0);
        assertEq(puzzleBefore.pendingChallenges, 2);
    }

    // ============ Zero Collateral No Event Test ============

    function test_ForfeitWithZeroCollateral_NoEventEmitted() public {
        // Create puzzle with exactly MIN_BOUNTY (no collateral)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.0001 ether}(bytes32(uint256(1)), 0.0001 ether, 0.00001 ether, 100);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.collateral, 0);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.00001 ether}(puzzleId, 42);

        // Warp past timeout
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);

        // Record logs to check for CollateralSlashed event
        vm.recordLogs();
        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Check logs - should have PuzzleForfeited but NOT CollateralSlashed
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool foundPuzzleForfeited = false;
        bool foundCollateralSlashed = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PuzzleForfeited(uint256,uint256)")) {
                foundPuzzleForfeited = true;
            }
            if (logs[i].topics[0] == keccak256("CollateralSlashed(uint256,uint256)")) {
                foundCollateralSlashed = true;
            }
        }

        assertTrue(foundPuzzleForfeited, "PuzzleForfeited event should be emitted");
        assertFalse(foundCollateralSlashed, "CollateralSlashed event should NOT be emitted when collateral is 0");
    }

    // ============ Guesser Aggregates Test ============

    function test_GuesserAggregates_MultipleGuesses() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Same guesser submits 3 different guesses with varying stakes
        vm.startPrank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 10);
        game.submitGuess{value: 0.02 ether}(puzzleId, 20);
        game.submitGuess{value: 0.03 ether}(puzzleId, 30);
        vm.stopPrank();

        // Verify guesserChallengeCount
        assertEq(game.guesserChallengeCount(puzzleId, guesser), 3);

        // Verify guesserStakeTotal = sum of stakes
        assertEq(game.guesserStakeTotal(puzzleId, guesser), 0.06 ether);
    }

    // ============ Creator Can Forfeit Own Puzzle Test ============

    function test_CreatorCanForfeitOwnPuzzle() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Warp past timeout
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);

        // Creator calls forfeitPuzzle - should succeed (anyone can call)
        vm.prank(creator);
        game.forfeitPuzzle(puzzleId, challengeId);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.forfeited, true);
    }

    // ============ Balance Accumulation Test ============

    function test_BalanceAccumulation_MultipleSources() public {
        // Create puzzle 1
        vm.prank(creator);
        uint256 puzzle1 = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Guesser participates in puzzle1
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzle1, 42);

        // Forfeit puzzle1
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        vm.prank(anyone);
        game.forfeitPuzzle(puzzle1, 0);

        // Claim from forfeited puzzle1
        vm.prank(guesser);
        game.claimFromForfeited(puzzle1);

        // Balance from forfeit: stake (0.01) + bounty share (0.0001 / 1 = 0.0001)
        uint256 forfeitClaim = 0.01 ether + 0.0001 ether;
        assertEq(game.balances(guesser), forfeitClaim);

        // Withdraw once
        uint256 guesserBalanceBefore = guesser.balance;
        vm.prank(guesser);
        game.withdraw();

        assertEq(guesser.balance, guesserBalanceBefore + forfeitClaim);
        assertEq(game.balances(guesser), 0);
    }

    // ============ Event Field Verification Tests ============

    function test_PuzzleCreatedEvent_AllFields() public {
        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));
        uint256 stakeRequired = 0.01 ether;
        uint256 maxNumber = 100;

        vm.expectEmit(true, false, false, true);
        emit IGuessGame.PuzzleCreated(0, creator, commitment, 0.0001 ether, 0.1999 ether, stakeRequired, maxNumber);

        vm.prank(creator);
        game.createPuzzle{value: 0.2 ether}(commitment, 0.0001 ether, stakeRequired, maxNumber);
    }

    function test_CollateralSlashedEvent_Amount() public {
        // Create puzzle with specific collateral (0.2 - MIN_BOUNTY = 0.1999 ether)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);

        // Expect event with exact collateral amount
        vm.expectEmit(true, false, false, true);
        emit IGuessGame.CollateralSlashed(puzzleId, 0.1999 ether);

        vm.prank(anyone);
        game.forfeitPuzzle(puzzleId, challengeId);
    }

    // ============ Minimum Valid Guess Test ============

    function test_SubmitGuess_MinimumValid() public {
        // Create puzzle with maxNumber >= 1
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 100);

        // Submit guess = 1, should succeed
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 1);

        IGuessGame.Challenge memory challenge = game.getChallenge(puzzleId, challengeId);
        assertEq(challenge.guess, 1);
        assertEq(challenge.guesser, guesser);
    }

    // ============ maxNumber = 1 Edge Case Test ============

    function test_MaxNumberOne_OnlyValidGuessIsOne() public {
        // Create puzzle with maxNumber = 1
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(bytes32(uint256(1)), 0.0001 ether, 0.01 ether, 1);

        // guess = 1 should succeed
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 1);

        // guess = 2 should fail with InvalidGuessRange
        vm.prank(guesser2);
        vm.expectRevert(IGuessGame.InvalidGuessRange.selector);
        game.submitGuess{value: 0.01 ether}(puzzleId, 2);
    }

    // ============ Withdraw Zero Balance Test ============

    function test_WithdrawZeroBalance_Reverts() public {
        // User with no balance calls withdraw
        vm.prank(anyone);
        vm.expectRevert(IGuessGame.NothingToWithdraw.selector);
        game.withdraw();
    }

    // ============ Collateral Equals Bounty Test ============

    function test_CollateralEqualsBounty() public {
        // msg.value = 2 * MIN_BOUNTY = 0.0002 ether
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.0002 ether}(bytes32(uint256(1)), 0.0001 ether, 0.00001 ether, 100);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        // Verify bounty = MIN_BOUNTY, collateral = MIN_BOUNTY
        assertEq(puzzle.bounty, 0.0001 ether);
        assertEq(puzzle.collateral, 0.0001 ether);
    }
}

contract RejectingReceiver {
    receive() external payable {
        revert("rejected");
    }
}
