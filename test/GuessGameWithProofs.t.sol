// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import {Rewards} from "../src/Rewards.sol";
import {AlwaysAcceptVerifier} from "./mocks/AlwaysAcceptVerifier.sol";

// Game-flow tests in this file exercise contract state transitions, not Groth16 math; the
// real circuit is exercised by integration tests in test/integration/DynamicProofTest.t.sol
// via FFI.
contract GuessGameWithProofsTest is Test {
    function deployGameProxy(address _verifier, address _treasury) internal returns (GuessGame) {
        GuessGame impl = new GuessGame();
        bytes memory initData = abi.encodeCall(GuessGame.initialize, (_verifier, _treasury, address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return GuessGame(address(proxy));
    }

    AlwaysAcceptVerifier public verifier;
    GuessGame public game;

    address creator;
    address guesser;
    address guesser2;

    // The mock verifier accepts any proof, so the bytewise contents don't matter; the contract
    // logic exercised by these tests reads pubSignals[0..5] directly. Real Groth16 round-tripping
    // is covered by integration/DynamicProofTest.t.sol.
    bytes32 constant COMMITMENT_42_123 = 0x1d869fb8246b6131377493aaaf1cc16a8284d4aedcb7277079df35d0d1d552d1;
    bytes32 constant COMMITMENT_50000_999 = 0x2cc18bc721abaa61b337c7223c0e0cfc2a80edfa8f5ba0a39b8c01285c78504a;

    uint256[2] validProofACorrect = [uint256(1), uint256(1)];
    uint256[2][2] validProofBCorrect = [[uint256(1), uint256(1)], [uint256(1), uint256(1)]];
    uint256[2] validProofCCorrect = [uint256(1), uint256(1)];

    function _pubSig(
        bytes32 commitment,
        uint256 isCorrect,
        uint256 guess,
        uint256 maxNumber,
        uint256 puzzleId,
        address guesserAddr
    ) internal pure returns (uint256[6] memory) {
        return [uint256(commitment), isCorrect, guess, maxNumber, puzzleId, uint256(uint160(guesserAddr))];
    }

    // Helpers are `pure` so they don't issue an external call that would consume vm.prank.
    function _sigCorrect(uint256 puzzleId, address guesserAddr) internal pure returns (uint256[6] memory) {
        return _pubSig(COMMITMENT_42_123, 1, 42, 100, puzzleId, guesserAddr);
    }

    function _sigIncorrect(uint256 puzzleId, address guesserAddr) internal pure returns (uint256[6] memory) {
        return _pubSig(COMMITMENT_42_123, 0, 50, 100, puzzleId, guesserAddr);
    }

    function _sigIncorrect99(uint256 puzzleId, address guesserAddr) internal pure returns (uint256[6] memory) {
        return _pubSig(COMMITMENT_42_123, 0, 99, 100, puzzleId, guesserAddr);
    }

    function _sigCorrect1000(uint256 puzzleId, address guesserAddr) internal pure returns (uint256[6] memory) {
        return _pubSig(COMMITMENT_42_123, 1, 42, 1000, puzzleId, guesserAddr);
    }

    function _sigIncorrect1000(uint256 puzzleId, address guesserAddr) internal pure returns (uint256[6] memory) {
        return _pubSig(COMMITMENT_42_123, 0, 50, 1000, puzzleId, guesserAddr);
    }

    function _sigCorrect65535(uint256 puzzleId, address guesserAddr) internal pure returns (uint256[6] memory) {
        return _pubSig(COMMITMENT_50000_999, 1, 50000, 65535, puzzleId, guesserAddr);
    }

    function _sigIncorrect65535(uint256 puzzleId, address guesserAddr) internal pure returns (uint256[6] memory) {
        return _pubSig(COMMITMENT_50000_999, 0, 12345, 65535, puzzleId, guesserAddr);
    }

    address treasury;

    function setUp() public {
        // Create test addresses that can receive ETH
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        guesser2 = makeAddr("guesser2");
        treasury = address(new Rewards(address(this)));

        // Deploy mock verifier (always-accepts) — game-flow tests, not Groth16 round-trip
        verifier = new AlwaysAcceptVerifier();
        // Deploy game via proxy
        game = deployGameProxy(address(verifier), treasury);

        vm.deal(creator, 10 ether);
        vm.deal(guesser, 10 ether);
        vm.deal(guesser2, 10 ether);
    }

    function test_RespondToChallenge_CorrectGuess_WithValidProof() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit correct guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Check initial state
        IGuessGame.Puzzle memory puzzleBefore = game.getPuzzle(puzzleId);
        assertEq(puzzleBefore.pendingChallenges, 1);
        assertEq(puzzleBefore.solved, false);

        uint256 guesserBalanceBefore = guesser.balance;

        // Respond with valid proof showing guess is correct
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect(puzzleId, guesser)
        );

        // Verify puzzle is solved
        IGuessGame.Puzzle memory puzzleAfter = game.getPuzzle(puzzleId);
        assertEq(puzzleAfter.solved, true);
        assertEq(puzzleAfter.pendingChallenges, 0);

        // Verify challenge is marked as responded
        IGuessGame.Challenge memory challenge = game.getChallenge(puzzleId, challengeId);
        assertEq(challenge.responded, true);

        // Verify winner received bounty + stake
        uint256 expectedPrize = 0.0001 ether + 0.01 ether; // bounty + stake
        assertEq(guesser.balance, guesserBalanceBefore + expectedPrize);
    }

    function test_RespondToChallenge_IncorrectGuess_WithValidProof() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit incorrect guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        uint256 guesserBalanceBefore = guesser.balance;

        // Respond with valid proof showing guess is incorrect
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        // Verify puzzle is NOT solved
        IGuessGame.Puzzle memory puzzleAfter = game.getPuzzle(puzzleId);
        assertEq(puzzleAfter.solved, false);
        assertEq(puzzleAfter.pendingChallenges, 0);

        // Verify guesser got their stake back (simplified economics)
        assertEq(guesser.balance, guesserBalanceBefore + 0.01 ether);
    }

    function test_RespondToChallenge_MultipleGuesses_ThenCorrect() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // First incorrect guess
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        uint256 guesser1BalanceBefore = guesser.balance;

        // Respond to first guess (incorrect) - guesser gets stake back
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        // Guesser should have stake back
        assertEq(guesser.balance, guesser1BalanceBefore + 0.01 ether);

        // Second incorrect guess from different guesser
        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        uint256 guesser2BalanceBefore = guesser2.balance;

        // Respond with proof for guess 99 (challengeId2 was submitted by guesser2)
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId2,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect99(puzzleId, guesser2)
        );

        // Guesser2 should have stake back
        assertEq(guesser2.balance, guesser2BalanceBefore + 0.01 ether);

        IGuessGame.Puzzle memory puzzleAfterIncorrect = game.getPuzzle(puzzleId);
        assertEq(puzzleAfterIncorrect.bounty, 0.0001 ether); // Bounty unchanged
        assertEq(puzzleAfterIncorrect.pendingChallenges, 0);

        // Now submit correct guess
        uint256 guesserBalanceBefore = guesser.balance;
        vm.prank(guesser);
        uint256 challengeId3 = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Respond with correct proof
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId3,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect(puzzleId, guesser)
        );

        // Verify puzzle is solved
        IGuessGame.Puzzle memory puzzleFinal = game.getPuzzle(puzzleId);
        assertEq(puzzleFinal.solved, true);

        // Winner gets bounty + stake back
        uint256 expectedWinnerPrize = 0.0001 ether + 0.01 ether;
        assertEq(guesser.balance, guesserBalanceBefore - 0.01 ether + expectedWinnerPrize);
    }

    function test_RespondToChallenge_AnyOrder() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit multiple guesses
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        // Respond out of order - challenge 2 first (should work with no queue enforcement)
        // challengeId2 was submitted by guesser2, so its binding is to guesser2.
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId2,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect99(puzzleId, guesser2)
        );

        // Then respond to challenge 1 with proof for guess 50
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        // Both challenges responded
        IGuessGame.Challenge memory c1 = game.getChallenge(puzzleId, challengeId1);
        IGuessGame.Challenge memory c2 = game.getChallenge(puzzleId, challengeId2);
        assertEq(c1.responded, true);
        assertEq(c2.responded, true);
    }

    function test_RespondToChallenge_InvalidCommitment_Reverts() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Wrong commitment should fail the puzzle.commitment match check.
        uint256[6] memory wrongPubSignals = _pubSig(
            bytes32(uint256(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef)),
            1,
            42,
            100,
            puzzleId,
            guesser
        );

        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidProof.selector);
        game.respondToChallenge(
            puzzleId, challengeId, validProofACorrect, validProofBCorrect, validProofCCorrect, wrongPubSignals
        );
    }

    function test_RespondToChallenge_InvalidProofForChallengeGuess() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Guesser submits guess 11
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 11);

        // Guesser submits guess 42
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Try to respond to challenge for guess 11 with proof for guess 42 - should fail
        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidProofForChallengeGuess.selector);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect(puzzleId, guesser)
        );

        // Try to respond to challenge for guess 42 with proof for guess 99 - should fail
        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidProofForChallengeGuess.selector);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect99(puzzleId, guesser)
        );
    }

    function test_RespondToChallenge_AlreadyResponded_Reverts() public {
        // Create puzzle and submit guess
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // First response
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        // Try to respond again
        vm.prank(creator);
        vm.expectRevert(IGuessGame.ChallengeAlreadyResponded.selector);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );
    }

    function test_RespondToChallenge_PuzzleAlreadySolved_Reverts() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // First guess (correct)
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Second guess
        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Solve puzzle with first guess
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect(puzzleId, guesser)
        );

        // Try to respond to second guess after puzzle is solved
        vm.prank(creator);
        vm.expectRevert(IGuessGame.PuzzleAlreadySolved.selector);
        game.respondToChallenge(
            puzzleId,
            challengeId2,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );
    }

    function test_CancelPuzzle_AfterAllResponsesProcessed() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Can't cancel with pending challenges
        vm.prank(creator);
        vm.expectRevert(IGuessGame.HasPendingChallenges.selector);
        game.cancelPuzzle(puzzleId);

        // Respond to challenge (guesser gets stake back)
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        // Can't cancel yet - timeout hasn't passed
        vm.prank(creator);
        vm.expectRevert(IGuessGame.CancelTooSoon.selector);
        game.cancelPuzzle(puzzleId);

        // Warp time past the timeout
        vm.warp(block.timestamp + game.CANCEL_TIMEOUT() + 1);

        uint256 creatorBalanceBefore = creator.balance;

        // Now can cancel after timeout
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        // Creator gets bounty + collateral back
        assertEq(creator.balance, creatorBalanceBefore + 0.2 ether);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.cancelled, true);
    }

    // ============ Forfeit Tests with Proofs ============

    function test_RespondToChallenge_PuzzleForfeited_Reverts() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Warp time and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Try to respond after forfeit - should fail
        vm.prank(creator);
        vm.expectRevert(IGuessGame.PuzzleForfeitedError.selector);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );
    }

    function test_ForfeitPuzzle_ChallengeAlreadyResponded_Reverts() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit two guesses
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        // Respond to challenge 1
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        // Warp time
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);

        // Try to forfeit using the responded challenge - should fail
        vm.expectRevert(IGuessGame.ChallengeAlreadyResponded.selector);
        game.forfeitPuzzle(puzzleId, challengeId1);

        // But can forfeit using challenge 2 (which was not responded)
        game.forfeitPuzzle(puzzleId, challengeId2);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.forfeited, true);
        assertEq(puzzle.pendingAtForfeit, 1); // Only challengeId2 was pending
    }

    function test_ForfeitAndClaim_AfterPartialResponses() public {
        // Create puzzle (bounty = MIN_BOUNTY = 0.0001, collateral = 0.2399)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.24 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit three guesses
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        address guesser3 = makeAddr("guesser3");
        vm.deal(guesser3, 10 ether);
        vm.prank(guesser3);
        uint256 challengeId3 = game.submitGuess{value: 0.01 ether}(puzzleId, 77);

        // Creator responds to challenge 1 only (guesser gets stake back)
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        // Warp time past timeout
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);

        // Forfeit using challenge 2
        game.forfeitPuzzle(puzzleId, challengeId2);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.forfeited, true);
        assertEq(puzzle.pendingAtForfeit, 2); // challenges 2 and 3 were pending

        // Both pending guessers claim (single call per guesser)
        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId);

        vm.prank(guesser3);
        game.claimFromForfeited(puzzleId);

        // Each gets stake (0.01) + bounty share (0.0001 / 2 = 0.00005)
        assertEq(game.balances(guesser2), 0.01 ether + 0.00005 ether);
        assertEq(game.balances(guesser3), 0.01 ether + 0.00005 ether);

        // Withdraw
        uint256 guesser2BalanceBefore = guesser2.balance;
        uint256 guesser3BalanceBefore = guesser3.balance;

        vm.prank(guesser2);
        game.withdraw();
        vm.prank(guesser3);
        game.withdraw();

        assertEq(guesser2.balance, guesser2BalanceBefore + 0.01005 ether);
        assertEq(guesser3.balance, guesser3BalanceBefore + 0.01005 ether);

        // guesser (who was responded to) has no pending challenges to claim
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.NothingToClaim.selector);
        game.claimFromForfeited(puzzleId);
    }

    // ============ Multi-Operation Scenario Test ============

    /**
     * @notice Complete game flow test:
     * 1. Creator creates a puzzle
     * 2. 2 guessers submit wrong guesses
     * 3. Creator tries to submit proofs for wrong guess numbers and fails
     * 4. Creator submits proper proofs (guessers get stakes back)
     * 5. 3rd guesser submits the right answer
     * 6. Creator responds and guesser wins bounty + stake
     */
    function test_CompleteGameFlow_WrongProofsThenCorrectWin() public {
        // Track balances
        uint256 creatorStartBalance = creator.balance;
        uint256 guesser1StartBalance = guesser.balance;
        uint256 guesser2StartBalance = guesser2.balance;

        // ========== Step 1: Creator creates puzzle ==========
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        assertEq(creator.balance, creatorStartBalance - 0.2 ether);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.creator, creator);
        assertEq(puzzle.bounty, 0.0001 ether);
        assertEq(puzzle.collateral, 0.1999 ether);
        assertEq(puzzle.solved, false);

        // ========== Step 2: 2 guessers submit wrong guesses ==========
        // Guesser 1 guesses 50 (wrong)
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 50);
        assertEq(guesser.balance, guesser1StartBalance - 0.01 ether);

        // Guesser 2 guesses 99 (wrong)
        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.01 ether}(puzzleId, 99);
        assertEq(guesser2.balance, guesser2StartBalance - 0.01 ether);

        puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingChallenges, 2);
        assertEq(puzzle.challengeCount, 2);

        // ========== Step 3: Creator tries wrong proofs and fails ==========
        // Try to respond to challenge for guess 50 with proof for guess 99
        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidProofForChallengeGuess.selector);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect99(puzzleId, guesser) // proof for guess 99
        );

        // Try to respond to challenge for guess 99 with proof for guess 50
        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidProofForChallengeGuess.selector);
        game.respondToChallenge(
            puzzleId,
            challengeId2,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser) // proof for guess 50
        );

        // Try to respond to wrong guess with correct proof (proof says correct but guess wasn't 42)
        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidProofForChallengeGuess.selector);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect(puzzleId, guesser) // proof for guess 42 (correct answer)
        );

        // Challenges should still be pending
        puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingChallenges, 2);

        // ========== Step 4: Creator submits proper proofs ==========
        // Respond to guess 50 with proof for guess 50
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        // Guesser 1 should have stake back
        assertEq(guesser.balance, guesser1StartBalance);

        // Respond to guess 99 with proof for guess 99 — challengeId2 was submitted by guesser2.
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId2,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect99(puzzleId, guesser2)
        );

        // Guesser 2 should have stake back
        assertEq(guesser2.balance, guesser2StartBalance);

        // Puzzle should still be unsolved with no pending challenges
        puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.solved, false);
        assertEq(puzzle.pendingChallenges, 0);
        assertEq(puzzle.bounty, 0.0001 ether); // Bounty intact

        // ========== Step 5: 3rd guesser submits the right answer ==========
        address guesser3 = makeAddr("guesser3");
        vm.deal(guesser3, 10 ether);
        uint256 guesser3StartBalance = guesser3.balance;

        vm.prank(guesser3);
        uint256 challengeId3 = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        assertEq(guesser3.balance, guesser3StartBalance - 0.01 ether);

        puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingChallenges, 1);
        assertEq(puzzle.challengeCount, 3);

        // ========== Step 6: Creator responds, guesser wins bounty + stake ==========
        // challengeId3 was submitted by guesser3.
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId3,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect(puzzleId, guesser3)
        );

        // Verify final state
        puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.solved, true);
        assertEq(puzzle.pendingChallenges, 0);

        // Winner (guesser3) gets bounty + stake
        uint256 expectedWinnerPrize = 0.0001 ether + 0.01 ether;
        assertEq(guesser3.balance, guesser3StartBalance - 0.01 ether + expectedWinnerPrize);
        assertEq(guesser3.balance, guesser3StartBalance + 0.0001 ether); // Net gain = bounty

        // Creator's ETH balance is down 0.2 ether (initial payment), but collateral credited to internal balance
        assertEq(creator.balance, creatorStartBalance - 0.2 ether);
        assertEq(game.balances(creator), 0.1999 ether); // Collateral returned

        // Guesser 1 and 2 are back to original balances (stakes returned)
        assertEq(guesser.balance, guesser1StartBalance);
        assertEq(guesser2.balance, guesser2StartBalance);

        // Verify challenges are marked as responded
        IGuessGame.Challenge memory c1 = game.getChallenge(puzzleId, challengeId1);
        IGuessGame.Challenge memory c2 = game.getChallenge(puzzleId, challengeId2);
        IGuessGame.Challenge memory c3 = game.getChallenge(puzzleId, challengeId3);
        assertEq(c1.responded, true);
        assertEq(c2.responded, true);
        assertEq(c3.responded, true);
    }

    /**
     * @notice Test that creator can respond to challenges in any order
     * Challenges submitted: 1, 2 (with guesses 50, 99)
     * Responses given: 2, 1 (reverse order)
     * Note: Limited to 2 challenges because we only have valid proofs for guesses 50 and 99
     */
    function test_ResponsesInAnyOrder() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit 2 guesses in order (we only have proofs for 50 and 99)
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingChallenges, 2);

        // Respond in reverse order: 2, 1 (not submission order)

        // First respond to challenge 2 (guess 99) — submitted by guesser2.
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId2,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect99(puzzleId, guesser2)
        );

        puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingChallenges, 1);
        assertEq(game.getChallenge(puzzleId, challengeId2).responded, true);
        assertEq(game.getChallenge(puzzleId, challengeId1).responded, false);

        // Then respond to challenge 1 (guess 50)
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingChallenges, 0);
        assertEq(game.getChallenge(puzzleId, challengeId1).responded, true);

        // All responded, puzzle still unsolved
        assertEq(puzzle.solved, false);
    }

    /**
     * @notice Test that after forfeit, guessers can claim in any order
     * Guessers: 1, 2, 3, 4
     * Claims made: 4, 2, 1, 3 (random order)
     */
    function test_ForfeitClaimsInAnyOrder() public {
        // Create puzzle with bounty divisible by 4
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Create 4 guessers and submit guesses
        address guesser3 = makeAddr("guesser3");
        address guesser4 = makeAddr("guesser4");
        vm.deal(guesser3, 10 ether);
        vm.deal(guesser4, 10 ether);

        uint256 guesser1Start = guesser.balance;
        uint256 guesser2Start = guesser2.balance;
        uint256 guesser3Start = guesser3.balance;
        uint256 guesser4Start = guesser4.balance;

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        vm.prank(guesser3);
        game.submitGuess{value: 0.01 ether}(puzzleId, 77);

        vm.prank(guesser4);
        game.submitGuess{value: 0.01 ether}(puzzleId, 88);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingChallenges, 4);

        // Warp time past timeout and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);

        puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.forfeited, true);
        assertEq(puzzle.pendingAtForfeit, 4);

        // Bounty is MIN_BOUNTY (0.0001 ether), collateral is 0.1999 ether
        // Each guesser should get: stake (0.01) + bounty share (0.0001 / 4 = 0.000025)
        uint256 expectedPayout = 0.01 ether + 0.000025 ether;

        // Claim in order: 4, 2, 1, 3 (not submission order) - single call per guesser
        vm.prank(guesser4);
        game.claimFromForfeited(puzzleId);
        assertEq(game.balances(guesser4), expectedPayout);

        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId);
        assertEq(game.balances(guesser2), expectedPayout);

        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);
        assertEq(game.balances(guesser), expectedPayout);

        vm.prank(guesser3);
        game.claimFromForfeited(puzzleId);
        assertEq(game.balances(guesser3), expectedPayout);

        // Withdraw all
        vm.prank(guesser4);
        game.withdraw();
        vm.prank(guesser2);
        game.withdraw();
        vm.prank(guesser);
        game.withdraw();
        vm.prank(guesser3);
        game.withdraw();

        // Verify net gains: each guesser gained 0.000025 ether (their share of 0.0001 ether bounty / 4)
        assertEq(guesser.balance, guesser1Start + 0.000025 ether);
        assertEq(guesser2.balance, guesser2Start + 0.000025 ether);
        assertEq(guesser3.balance, guesser3Start + 0.000025 ether);
        assertEq(guesser4.balance, guesser4Start + 0.000025 ether);
    }

    // ============ Protocol Hole Tests (These SHOULD FAIL until fixed) ============

    /**
     * @notice Test that guessers can recover stakes when puzzle is solved with pending challenges
     *
     * Scenario:
     * 1. Guesser A submits correct guess (42)
     * 2. Guesser B submits wrong guess (50)
     * 3. Creator responds to A first → puzzle solved, A wins
     * 4. Guesser B can call claimStakeFromSolved to recover their stake
     */
    function test_ClaimStakeFromSolved() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        uint256 guesser1Start = guesser.balance;
        uint256 guesser2Start = guesser2.balance;

        // Guesser 1 submits correct guess (42)
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Guesser 2 submits wrong guess (50)
        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Creator responds to guesser 1 (correct) - puzzle is solved
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect(puzzleId, guesser)
        );

        // Guesser 1 wins bounty + stake
        assertEq(guesser.balance, guesser1Start + 0.0001 ether);

        // Puzzle is solved, guesser 2's challenge is still pending
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.solved, true);

        // Guesser 2 claims their stake back (single call)
        vm.prank(guesser2);
        game.claimStakeFromSolved(puzzleId);

        // Balance should be credited
        assertEq(game.balances(guesser2), 0.01 ether);

        // Withdraw
        vm.prank(guesser2);
        game.withdraw();

        // Guesser 2 should have their stake returned
        assertEq(guesser2.balance, guesser2Start, "Guesser 2 should have stake returned");

        // Creator has collateral in internal balance
        assertEq(game.balances(creator), 0.1999 ether, "Creator should have collateral in balance");

        // Creator withdraws collateral
        vm.prank(creator);
        game.withdraw();

        // Contract should have no funds left
        assertEq(address(game).balance, 0, "Contract should have no stuck funds");
    }

    /**
     * @notice Test bounty distribution with rounding
     *
     * With per-guesser aggregates, each guesser gets proportional share.
     * Minimal dust (1-2 wei) may remain in contract from integer division.
     */
    function test_BountyDistributionWithRounding() public {
        // Create puzzle with bounty that won't divide evenly by 3
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Create 3 guessers
        address guesser3 = makeAddr("guesser3");
        vm.deal(guesser3, 10 ether);

        uint256 guesser1Start = guesser.balance;
        uint256 guesser2Start = guesser2.balance;
        uint256 guesser3Start = guesser3.balance;

        // All 3 submit guesses (unique numbers)
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        vm.prank(guesser3);
        game.submitGuess{value: 0.01 ether}(puzzleId, 77);

        // Forfeit the puzzle
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);

        // Calculate expected shares (cumulative division: last claimant gets remainder)
        uint256 bounty = 0.0001 ether;
        uint256 share1 = bounty / 3; // floor(bounty*1/3)
        uint256 share2 = (bounty * 2) / 3 - share1; // floor(bounty*2/3) - floor(bounty*1/3)
        uint256 share3 = bounty - (bounty * 2) / 3; // bounty - floor(bounty*2/3)

        // All guessers claim (single call each)
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId);

        vm.prank(guesser3);
        game.claimFromForfeited(puzzleId);

        // Verify balances credited
        assertEq(game.balances(guesser), 0.01 ether + share1);
        assertEq(game.balances(guesser2), 0.01 ether + share2);
        assertEq(game.balances(guesser3), 0.01 ether + share3);

        // Total bounty distributed exactly
        assertEq(share1 + share2 + share3, bounty);

        // Withdraw all
        vm.prank(guesser);
        game.withdraw();
        vm.prank(guesser2);
        game.withdraw();
        vm.prank(guesser3);
        game.withdraw();

        // Each guesser gained their bounty share
        assertEq(guesser.balance, guesser1Start + share1);
        assertEq(guesser2.balance, guesser2Start + share2);
        assertEq(guesser3.balance, guesser3Start + share3);
    }

    // ============ Protocol Issue Tests ============

    /**
     * @notice Protocol should enforce minimum stake at puzzle creation
     */
    function test_MinimumStakeRequired() public {
        vm.prank(creator);
        vm.expectRevert(IGuessGame.InsufficientStake.selector);
        game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0, 100);
    }

    /**
     * @notice Same guesser can submit multiple challenges (by design)
     *
     * This is acceptable because guessers risk their own funds. The "dilution attack"
     * mentioned in GitHub Issue #10 requires attacker to stake their own funds,
     * and forfeit is a recovery mechanism, not the intended path.
     */
    function test_SameGuesserMultipleChallenges_DesignDecision() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        uint256 guesserStart = guesser.balance;

        // Same guesser submits 3 different guesses
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 77);

        assertEq(guesser.balance, guesserStart - 0.03 ether);

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingAtForfeit, 3);

        // Single claim for all challenges
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        // Balance credited: 3 stakes + entire bounty (3/3 share)
        assertEq(game.balances(guesser), 0.03 ether + 0.0001 ether);

        // Withdraw
        vm.prank(guesser);
        game.withdraw();

        // Guesser gets stakes back + entire bounty
        assertEq(guesser.balance, guesserStart + 0.0001 ether);
    }

    /**
     * @notice Creator cannot guess their own puzzle
     *
     * Related: GitHub Issue #10 - https://github.com/chainhackers/zk-guess-contracts/issues/10
     */
    function test_CreatorCannotSelfGuess() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(creator);
        vm.expectRevert(IGuessGame.CreatorCannotGuess.selector);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);
    }

    /**
     * @notice Two players claim for 3 guesses where one player has 2 guesses
     *
     * Guesser1: 2 challenges (0.01 + 0.02 = 0.03 ether stake)
     * Guesser2: 1 challenge (0.01 ether stake)
     * Bounty: 0.15 ether, split by challenge count (2:1)
     */
    function test_TwoPlayersClaim_OneWithMultipleGuesses() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.3 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        uint256 guesser1Start = guesser.balance;
        uint256 guesser2Start = guesser2.balance;

        // Guesser1 submits 2 guesses
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser);
        game.submitGuess{value: 0.02 ether}(puzzleId, 99);

        // Guesser2 submits 1 guess
        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId, 77);

        // Forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingAtForfeit, 3);

        // Both claim (single call each)
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId);

        // Cumulative division: guesser1 claims first (c=2), guesser2 claims second (c=1)
        // guesser1: floor(bounty*2/3) = 66666666666666
        // guesser2: bounty - floor(bounty*2/3) = 33333333333334 (gets remainder)
        uint256 bounty = 0.0001 ether;
        uint256 share1 = (bounty * 2) / 3;
        uint256 share2 = bounty - share1;

        assertEq(game.balances(guesser), 0.03 ether + share1);
        assertEq(game.balances(guesser2), 0.01 ether + share2);
        assertEq(share1 + share2, bounty);

        // Withdraw
        vm.prank(guesser);
        game.withdraw();
        vm.prank(guesser2);
        game.withdraw();

        assertEq(guesser.balance, guesser1Start + share1);
        assertEq(guesser2.balance, guesser2Start + share2);
    }

    /**
     * @notice Players claim from multiple puzzles and withdraw combined balance
     *
     * Puzzle 1: Forfeited, guesser gets stake + bounty
     * Puzzle 2: Solved by guesser2, guesser gets stake back
     * Both withdraw their accumulated balances in single call
     */
    function test_ClaimFromMultiplePuzzles_ThenWithdraw() public {
        uint256 guesser1Start = guesser.balance;
        uint256 guesser2Start = guesser2.balance;

        // ========== Puzzle 1: Will be forfeited ==========
        vm.prank(creator);
        uint256 puzzleId1 = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId1, 50);

        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId1, 99);

        // ========== Puzzle 2: Will be solved by guesser2 ==========
        vm.prank(creator);
        uint256 puzzleId2 = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.02 ether}(puzzleId2, 50);

        vm.prank(guesser2);
        game.submitGuess{value: 0.02 ether}(puzzleId2, 42); // correct guess

        // ========== Puzzle 1: Forfeit ==========
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId1, 0);

        // Both claim from puzzle 1
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId1);
        // guesser: 0.01 stake + 0.00005 bounty (0.0001/2)

        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId1);
        // guesser2: 0.01 stake + 0.00005 bounty (0.0001/2)

        // ========== Puzzle 2: Solve ==========
        // Reset time for puzzle 2 responses
        vm.warp(block.timestamp - game.RESPONSE_TIMEOUT());

        // Creator responds to guesser's wrong guess
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId2, 0, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigIncorrect(puzzleId2, guesser)
        );
        // guesser gets 0.02 stake back immediately

        // Creator responds to guesser2's correct guess - puzzle solved
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId2, 1, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigCorrect(puzzleId2, guesser2)
        );
        // guesser2 gets 0.02 stake + 0.0001 bounty immediately

        // ========== Check balances before withdraw ==========
        // Guesser: 0.01 + 0.00005 from puzzle 1 forfeit claim
        assertEq(game.balances(guesser), 0.01 ether + 0.00005 ether);

        // Guesser2: 0.01 + 0.00005 from puzzle 1 forfeit claim
        assertEq(game.balances(guesser2), 0.01 ether + 0.00005 ether);

        // ========== Withdraw ==========
        vm.prank(guesser);
        game.withdraw();

        vm.prank(guesser2);
        game.withdraw();

        // ========== Verify final balances ==========
        // Bounty is MIN_BOUNTY (0.0001 ether) per puzzle, collateral is 0.1999 ether
        // Guesser: started, paid 0.01+0.02=0.03 stakes, got back:
        //   - 0.02 immediately from puzzle2 response
        //   - 0.01005 from withdraw (puzzle1 claim: 0.01 stake + 0.00005 bounty share)
        // Net: +0.00005 (bounty share from puzzle1)
        assertEq(guesser.balance, guesser1Start + 0.00005 ether);

        // Guesser2: started, paid 0.01+0.02=0.03 stakes, got back:
        //   - 0.02+0.0001=0.0201 immediately from puzzle2 win (bounty is 0.0001 ether)
        //   - 0.01005 from withdraw (puzzle1 claim: 0.01 stake + 0.00005 bounty share)
        // Net: +0.00005 (puzzle1 share) + 0.0001 (puzzle2 bounty) = +0.00015
        assertEq(guesser2.balance, guesser2Start + 0.00015 ether);
    }

    // ============ Additional Coverage Tests ============

    /**
     * @notice Multiple guessers claim stakes from a solved puzzle
     */
    function test_ClaimStakeFromSolved_MultipleGuessers() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        uint256 guesser1Start = guesser.balance;
        uint256 guesser2Start = guesser2.balance;

        address guesser3 = makeAddr("guesser3");
        vm.deal(guesser3, 10 ether);
        uint256 guesser3Start = guesser3.balance;

        // Three guessers submit - guesser3 will win
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser2);
        game.submitGuess{value: 0.02 ether}(puzzleId, 99);

        vm.prank(guesser3);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42); // correct

        // Creator responds to guesser3's correct guess first - puzzle solved
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId, 2, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigCorrect(puzzleId, guesser3)
        );

        // guesser3 wins bounty + stake immediately
        assertEq(guesser3.balance, guesser3Start + 0.0001 ether);

        // Other guessers claim their stakes back
        vm.prank(guesser);
        game.claimStakeFromSolved(puzzleId);

        vm.prank(guesser2);
        game.claimStakeFromSolved(puzzleId);

        assertEq(game.balances(guesser), 0.01 ether);
        assertEq(game.balances(guesser2), 0.02 ether);

        // Withdraw
        vm.prank(guesser);
        game.withdraw();
        vm.prank(guesser2);
        game.withdraw();

        assertEq(guesser.balance, guesser1Start);
        assertEq(guesser2.balance, guesser2Start);
    }

    /**
     * @notice Balance accumulates from both forfeit and solved claims
     */
    function test_BalanceAccumulates_MixedClaimTypes() public {
        uint256 guesserStart = guesser.balance;

        // Puzzle 1: Will be forfeited
        vm.prank(creator);
        uint256 puzzleId1 = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId1, 50);

        // Puzzle 2: Will be solved by someone else
        vm.prank(creator);
        uint256 puzzleId2 = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.02 ether}(puzzleId2, 50);

        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId2, 42); // winner

        // Forfeit puzzle 1
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId1, 0);

        vm.prank(guesser);
        game.claimFromForfeited(puzzleId1);
        // guesser: 0.01 stake + 0.0001 bounty = 0.0101

        // Solve puzzle 2 — challenge index 1 was submitted by guesser2.
        vm.warp(block.timestamp - game.RESPONSE_TIMEOUT());
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId2, 1, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigCorrect(puzzleId2, guesser2)
        );

        // guesser claims stake from solved puzzle
        vm.prank(guesser);
        game.claimStakeFromSolved(puzzleId2);
        // guesser: adds 0.02 stake

        // Combined balance: 0.0101 + 0.02 = 0.0301
        assertEq(game.balances(guesser), 0.0101 ether + 0.02 ether);

        // Single withdraw gets everything
        vm.prank(guesser);
        game.withdraw();

        // Net: paid 0.03 stakes, got 0.0301 back = +0.0001 (bounty from puzzle1)
        assertEq(guesser.balance, guesserStart + 0.0001 ether);
    }

    /**
     * @notice Withdraw with zero balance reverts
     */
    function test_Withdraw_ZeroBalance() public {
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.NothingToWithdraw.selector);
        game.withdraw();
    }

    /**
     * @notice Second withdraw after first succeeds reverts
     */
    function test_Withdraw_MultipleTimes() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);

        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        // First withdraw succeeds
        vm.prank(guesser);
        game.withdraw();

        // Second withdraw fails
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.NothingToWithdraw.selector);
        game.withdraw();
    }

    /**
     * @notice Guesser with multiple challenges claims all at once from solved puzzle
     */
    function test_ClaimStakeFromSolved_GuesserWithMultipleChallenges() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        uint256 guesserStart = guesser.balance;

        // Guesser submits 3 wrong guesses
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser);
        game.submitGuess{value: 0.02 ether}(puzzleId, 99);

        vm.prank(guesser);
        game.submitGuess{value: 0.03 ether}(puzzleId, 77);

        // guesser2 wins
        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Challenge index 3 was submitted by guesser2 (the winner).
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId, 3, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigCorrect(puzzleId, guesser2)
        );

        // Guesser claims all 3 stakes in one call
        vm.prank(guesser);
        game.claimStakeFromSolved(puzzleId);

        assertEq(game.balances(guesser), 0.06 ether); // 0.01 + 0.02 + 0.03

        vm.prank(guesser);
        game.withdraw();

        assertEq(guesser.balance, guesserStart); // got all stakes back
    }

    /**
     * @notice Winner's aggregates are zeroed so they cannot claim
     */
    function test_ClaimStakeFromSolved_WinnerCannotClaim() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42); // correct

        vm.prank(creator);
        game.respondToChallenge(
            puzzleId, 0, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigCorrect(puzzleId, guesser)
        );

        // Winner's aggregates are decremented to 0
        assertEq(game.guesserStakeTotal(puzzleId, guesser), 0);
        assertEq(game.guesserChallengeCount(puzzleId, guesser), 0);

        // Winner tries to claim - nothing to claim
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.NothingToClaim.selector);
        game.claimStakeFromSolved(puzzleId);
    }

    /**
     * @notice Verify aggregates decrement correctly after respondToChallenge
     */
    function test_AggregatesDecrementOnResponse() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Guesser submits 2 guesses
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser);
        game.submitGuess{value: 0.02 ether}(puzzleId, 99);

        // Check initial aggregates
        assertEq(game.guesserStakeTotal(puzzleId, guesser), 0.03 ether);
        assertEq(game.guesserChallengeCount(puzzleId, guesser), 2);

        // Respond to first challenge
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId, 0, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigIncorrect(puzzleId, guesser)
        );

        // Aggregates decremented
        assertEq(game.guesserStakeTotal(puzzleId, guesser), 0.02 ether);
        assertEq(game.guesserChallengeCount(puzzleId, guesser), 1);

        // Respond to second challenge
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId, 1, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigIncorrect99(puzzleId, guesser)
        );

        // Aggregates now zero
        assertEq(game.guesserStakeTotal(puzzleId, guesser), 0);
        assertEq(game.guesserChallengeCount(puzzleId, guesser), 0);
    }

    /**
     * @notice Cannot claim from unsolved puzzle
     */
    function test_ClaimStakeFromSolved_UnsolvedPuzzle() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser);
        vm.expectRevert(IGuessGame.PuzzleNotSolved.selector);
        game.claimStakeFromSolved(puzzleId);
    }

    /**
     * @notice Cannot claim from cancelled puzzle
     */
    function test_ClaimFromCancelledPuzzle() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Warp past cancel timeout and cancel
        vm.warp(block.timestamp + game.CANCEL_TIMEOUT() + 1);
        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        // Cannot claim forfeit
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.PuzzleNotForfeited.selector);
        game.claimFromForfeited(puzzleId);

        // Cannot claim solved
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.PuzzleNotSolved.selector);
        game.claimStakeFromSolved(puzzleId);
    }

    /**
     * @notice Balance accumulates from multiple forfeited puzzles
     */
    function test_BalanceAccumulates_MultipleForfeitedPuzzles() public {
        uint256 guesserStart = guesser.balance;

        // Create and forfeit 3 puzzles
        uint256[] memory puzzleIds = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(creator);
            puzzleIds[i] = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

            vm.prank(guesser);
            game.submitGuess{value: 0.01 ether}(puzzleIds[i], 50);
        }

        // Forfeit all
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        for (uint256 i = 0; i < 3; i++) {
            game.forfeitPuzzle(puzzleIds[i], 0);
        }

        // Claim from all
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(guesser);
            game.claimFromForfeited(puzzleIds[i]);
        }

        // Balance = 3 * (0.01 stake + 0.0001 bounty) = 0.0303 ether
        assertEq(game.balances(guesser), 0.0303 ether);

        // Single withdraw
        vm.prank(guesser);
        game.withdraw();

        // Net gain = 3 * 0.0001 bounty = 0.0003 ether
        assertEq(guesser.balance, guesserStart + 0.0003 ether);
    }

    /**
     * @notice Single guesser on forfeit gets entire bounty
     */
    function test_SingleGuesserForfeit_GetsEntireBounty() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 1 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        uint256 guesserStart = guesser.balance;

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);

        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        // Gets stake + entire bounty (bounty is MIN_BOUNTY = 0.0001)
        assertEq(game.balances(guesser), 0.01 ether + 0.0001 ether);

        vm.prank(guesser);
        game.withdraw();

        assertEq(guesser.balance, guesserStart + 0.0001 ether);
    }

    /**
     * @notice Forfeit claim works correctly at MIN_STAKE
     */
    function test_MinStake_ForfeitClaim() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.00001 ether, 100);

        uint256 guesserStart = guesser.balance;

        // Submit at exactly MIN_STAKE
        vm.prank(guesser);
        game.submitGuess{value: 0.00001 ether}(puzzleId, 50);

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);

        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        // Gets MIN_STAKE + entire bounty
        assertEq(game.balances(guesser), 0.00001 ether + 0.0001 ether);

        vm.prank(guesser);
        game.withdraw();

        assertEq(guesser.balance, guesserStart + 0.0001 ether);
    }

    // ============ Collateral Tests ============

    /**
     * @notice Verify creator gets collateral back when puzzle is solved (correct guess)
     */
    function test_CorrectGuessReturnsCollateralToCreator() public {
        uint256 creatorStart = creator.balance;

        // Create puzzle with 0.2 ether (0.1 bounty + 0.1 collateral)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        assertEq(creator.balance, creatorStart - 0.2 ether);

        // Submit correct guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Respond with correct proof
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect(puzzleId, guesser)
        );

        // Creator's collateral should be credited to internal balance
        assertEq(game.balances(creator), 0.1999 ether);

        // Creator withdraws collateral
        vm.prank(creator);
        game.withdraw();

        // Creator now has: original - 0.2 (paid) + 0.1999 (collateral) = original - 0.0001 (lost bounty only)
        assertEq(creator.balance, creatorStart - 0.0001 ether);
    }

    /**
     * @notice Verify duplicate guesses are rejected (basic test with proofs)
     */
    function test_DuplicateGuessRejected() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // First guess succeeds
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Duplicate guess from different guesser fails
        vm.prank(guesser2);
        vm.expectRevert(IGuessGame.GuessAlreadySubmitted.selector);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);
    }

    /**
     * @notice Verify collateral is still fully slashed after partial responses
     */
    function test_ForfeitAfterPartialResponses_CollateralStillSlashed() public {
        uint256 treasuryStart = treasury.balance;

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.24 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit three guesses
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        address guesser3 = makeAddr("guesser3");
        vm.deal(guesser3, 10 ether);
        vm.prank(guesser3);
        game.submitGuess{value: 0.01 ether}(puzzleId, 77);

        // Creator responds to challenge 0 only
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId, 0, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigIncorrect(puzzleId, guesser)
        );

        // Warp and forfeit using challenge 1
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 1);

        // Treasury gets FULL collateral (0.2399 ether = 0.24 - MIN_BOUNTY), not partial
        assertEq(treasury.balance, treasuryStart + 0.2399 ether);
    }

    /**
     * @notice All incorrect guesses responded - creator keeps collateral on cancel
     */
    function test_AllIncorrectGuesses_NoSlashing() public {
        uint256 treasuryStart = treasury.balance;

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit 2 wrong guesses
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        // Creator responds to both
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId, 0, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigIncorrect(puzzleId, guesser)
        );

        vm.prank(creator);
        game.respondToChallenge(
            puzzleId, 1, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigIncorrect99(puzzleId, guesser2)
        );

        // Warp past cancel timeout and cancel
        vm.warp(block.timestamp + game.CANCEL_TIMEOUT() + 1);

        uint256 creatorBalanceBefore = creator.balance;

        vm.prank(creator);
        game.cancelPuzzle(puzzleId);

        // Creator gets bounty + collateral back
        assertEq(creator.balance, creatorBalanceBefore + 0.2 ether);

        // Treasury unchanged - no slashing
        assertEq(treasury.balance, treasuryStart);
    }

    /**
     * @notice Verify collateral is slashed to treasury on forfeit
     */
    function test_ForfeitSlashesCollateral() public {
        uint256 treasuryStart = treasury.balance;

        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Warp and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Treasury receives collateral
        assertEq(treasury.balance, treasuryStart + 0.1999 ether);

        // Guesser can still claim bounty share
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);
        assertEq(game.balances(guesser), 0.01 ether + 0.0001 ether); // stake + entire bounty
    }

    // ============ Tests for maxNumber > 100 ============

    /**
     * @notice Test puzzle with maxNumber=1000 - correct guess
     */
    function test_MaxNumber1000_CorrectGuess() public {
        // Create puzzle with maxNumber=1000
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 1000);

        // Verify maxNumber stored correctly
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.maxNumber, 1000);

        // Submit correct guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        uint256 guesserBalanceBefore = guesser.balance;

        // Respond with valid proof for maxNumber=1000
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect1000(puzzleId, guesser)
        );

        // Verify puzzle is solved
        assertTrue(game.getPuzzle(puzzleId).solved);

        // Winner gets bounty + stake
        uint256 expectedPrize = 0.0001 ether + 0.01 ether;
        assertEq(guesser.balance, guesserBalanceBefore + expectedPrize);
    }

    /**
     * @notice Test puzzle with maxNumber=1000 - incorrect guess
     */
    function test_MaxNumber1000_IncorrectGuess() public {
        // Create puzzle with maxNumber=1000
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 1000);

        // Submit incorrect guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        uint256 guesserBalanceBefore = guesser.balance;

        // Respond with valid proof for incorrect guess
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect1000(puzzleId, guesser)
        );

        // Puzzle not solved
        assertFalse(game.getPuzzle(puzzleId).solved);

        // Guesser gets stake back
        assertEq(guesser.balance, guesserBalanceBefore + 0.01 ether);
    }

    /**
     * @notice Test puzzle with maxNumber=65535 (full 16-bit range) - large secret number
     */
    function test_MaxNumber65535_LargeSecret_CorrectGuess() public {
        // Create puzzle with maxNumber=65535 and large secret (50000)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_50000_999, 0.0001 ether, 0.01 ether, 65535);

        // Verify maxNumber stored correctly
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.maxNumber, 65535);

        // Submit correct guess (50000)
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50000);

        uint256 guesserBalanceBefore = guesser.balance;

        // Respond with valid proof for maxNumber=65535
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect65535(puzzleId, guesser)
        );

        // Verify puzzle is solved
        assertTrue(game.getPuzzle(puzzleId).solved);

        // Winner gets bounty + stake
        uint256 expectedPrize = 0.0001 ether + 0.01 ether;
        assertEq(guesser.balance, guesserBalanceBefore + expectedPrize);
    }

    /**
     * @notice Test puzzle with maxNumber=65535 - incorrect guess
     */
    function test_MaxNumber65535_LargeSecret_IncorrectGuess() public {
        // Create puzzle with maxNumber=65535 and large secret (50000)
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_50000_999, 0.0001 ether, 0.01 ether, 65535);

        // Submit incorrect guess (12345)
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 12345);

        uint256 guesserBalanceBefore = guesser.balance;

        // Respond with valid proof for incorrect guess
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect65535(puzzleId, guesser)
        );

        // Puzzle not solved
        assertFalse(game.getPuzzle(puzzleId).solved);

        // Guesser gets stake back
        assertEq(guesser.balance, guesserBalanceBefore + 0.01 ether);
    }

    /**
     * @notice Test that proof with wrong maxNumber is rejected
     */
    function test_MaxNumber_MismatchRejected() public {
        // Create puzzle with maxNumber=1000
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 1000);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Try to respond with proof for maxNumber=100 (mismatch)
        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidProof.selector);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigCorrect(puzzleId, guesser) // This has maxNumber=100, but puzzle has maxNumber=1000
        );
    }

    // ============ Additional High Priority Tests ============

    /**
     * @notice Verify that responding to one challenge resets the timeout clock
     *
     * - Create puzzle, submit 2 guesses
     * - Respond to first guess (lastResponseTime updated)
     * - Wait RESPONSE_TIMEOUT from original challenge.timestamp (not enough)
     * - Try forfeit - should fail because lastResponseTime reset the clock
     * - Wait RESPONSE_TIMEOUT from lastResponseTime
     * - Forfeit should now succeed
     */
    function test_ForfeitTimeoutResetsOnResponse() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit two guesses
        vm.prank(guesser);
        uint256 challengeId1 = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Advance time slightly before submitting second guess
        vm.warp(block.timestamp + 1 hours);

        vm.prank(guesser2);
        uint256 challengeId2 = game.submitGuess{value: 0.01 ether}(puzzleId, 99);

        // Respond to first guess (this should update lastResponseTime)
        vm.warp(block.timestamp + 1 hours);

        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId1,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        // Verify lastResponseTime was updated and get timestamps from storage
        // (local variable capture is unreliable under coverage instrumentation)
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        IGuessGame.Challenge memory challenge1 = game.getChallenge(puzzleId, challengeId1);
        assertEq(puzzle.pendingChallenges, 1); // Only challenge 2 is pending

        // Warp to RESPONSE_TIMEOUT from original challenge1 timestamp
        // This would be enough time from the first challenge, but NOT from the response
        vm.warp(challenge1.timestamp + game.RESPONSE_TIMEOUT() + 1);

        // Forfeit should fail - creator responded within timeout (lastResponseTime resets the clock)
        vm.expectRevert(IGuessGame.CreatorStillActive.selector);
        game.forfeitPuzzle(puzzleId, challengeId2);

        // Now warp to RESPONSE_TIMEOUT from the response time
        vm.warp(puzzle.lastResponseTime + game.RESPONSE_TIMEOUT());

        // Forfeit should succeed now
        game.forfeitPuzzle(puzzleId, challengeId2);

        puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.forfeited, true);
    }

    /**
     * @notice Test that puzzle with all challenges responded cannot be forfeited
     *
     * - Create puzzle, submit guess
     * - Respond to challenge (pendingChallenges = 0)
     * - Warp past RESPONSE_TIMEOUT
     * - Try forfeit - should fail (ChallengeAlreadyResponded on any challenge, or no pending challenges)
     */
    function test_CannotForfeitAfterAllChallengesResponded() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Respond to challenge
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            validProofACorrect,
            validProofBCorrect,
            validProofCCorrect,
            _sigIncorrect(puzzleId, guesser)
        );

        // Verify pendingChallenges is 0
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.pendingChallenges, 0);
        assertFalse(puzzle.solved);
        assertFalse(puzzle.forfeited);

        // Warp past RESPONSE_TIMEOUT
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);

        // Try to forfeit using the responded challenge - should fail
        vm.expectRevert(IGuessGame.ChallengeAlreadyResponded.selector);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Puzzle should still not be forfeited
        puzzle = game.getPuzzle(puzzleId);
        assertFalse(puzzle.forfeited);
    }

    /**
     * @notice Test balance accumulation from solved puzzle claim + forfeited puzzle claim
     *
     * - Guesser participates in puzzle1 (forfeited) and puzzle2 (solved, not winner)
     * - Claim from both puzzles
     * - Verify total balance = forfeit_claim + solved_stake_claim
     * - Withdraw once, verify correct total
     */
    function test_BalanceAccumulation_ForfeitAndSolvedClaims() public {
        uint256 guesserStart = guesser.balance;

        // ========== Puzzle 1: Will be forfeited ==========
        vm.prank(creator);
        uint256 puzzleId1 = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId1, 50);

        // ========== Puzzle 2: Will be solved by guesser2 ==========
        vm.prank(creator);
        uint256 puzzleId2 = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.02 ether}(puzzleId2, 50); // Wrong guess

        vm.prank(guesser2);
        game.submitGuess{value: 0.01 ether}(puzzleId2, 42); // Correct guess

        // ========== Forfeit puzzle 1 ==========
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId1, 0);

        vm.prank(guesser);
        game.claimFromForfeited(puzzleId1);
        // Claim: 0.01 stake + 0.0001 bounty = 0.0101

        // ========== Solve puzzle 2 ==========
        vm.warp(block.timestamp - game.RESPONSE_TIMEOUT()); // Reset time for responses

        // Respond to guesser2's correct guess (challenge index 1) - puzzle solved.
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId2, 1, validProofACorrect, validProofBCorrect, validProofCCorrect, _sigCorrect(puzzleId2, guesser2)
        );

        // Guesser claims stake from solved puzzle
        vm.prank(guesser);
        game.claimStakeFromSolved(puzzleId2);
        // Claim: 0.02 stake

        // ========== Verify combined balance ==========
        // Total: 0.0101 (from forfeit) + 0.02 (from solved) = 0.0301
        assertEq(game.balances(guesser), 0.0301 ether);

        // ========== Single withdraw ==========
        vm.prank(guesser);
        game.withdraw();

        // Net: paid 0.03 stakes, got 0.0301 back = +0.0001 (bounty from puzzle1)
        assertEq(guesser.balance, guesserStart + 0.0001 ether);
    }
}
