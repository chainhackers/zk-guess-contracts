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
    
    function setUp() public {
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        
        vm.deal(creator, 10 ether);
        vm.deal(guesser, 10 ether);
        
        // Deploy verifier first
        verifier = new Groth16Verifier();
        // Deploy game with verifier address
        game = new GuessGame(address(verifier));
    }
    
    function test_CreatePuzzle() public {
        vm.startPrank(creator);
        
        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123))); // number=42, salt=123
        uint256 stakeRequired = 0.01 ether;
        uint8 bountyGrowthPercent = 50;
        
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(
            commitment,
            stakeRequired,
            bountyGrowthPercent
        );
        
        assertEq(puzzleId, 1);
        assertEq(game.puzzleCount(), 1);
        
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.creator, creator);
        assertEq(puzzle.commitment, commitment);
        assertEq(puzzle.bounty, 0.1 ether);
        assertEq(puzzle.stakeRequired, stakeRequired);
        assertEq(puzzle.bountyGrowthPercent, bountyGrowthPercent);
        assertEq(puzzle.totalStaked, 0);
        assertEq(puzzle.solved, false);
        
        vm.stopPrank();
    }
    
    function test_CreatePuzzle_InsufficientBounty() public {
        vm.startPrank(creator);
        
        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));
        
        vm.expectRevert(IGuessGame.InsufficientBounty.selector);
        game.createPuzzle{value: 0.0001 ether}(commitment, 0.01 ether, 50);
        
        vm.stopPrank();
    }
    
    function test_SubmitGuess() public {
        // First create a puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(
            keccak256(abi.encodePacked(uint256(42), uint256(123))),
            0.01 ether,
            50
        );
        
        // Submit a guess
        vm.startPrank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);
        
        assertEq(challengeId, 1);
        assertEq(game.challengeCount(), 1);
        
        IGuessGame.Challenge memory challenge = game.getChallenge(challengeId);
        assertEq(challenge.guesser, guesser);
        assertEq(challenge.guess, 50);
        assertEq(challenge.stake, 0.01 ether);
        assertEq(challenge.responded, false);
        
        // Check puzzle was updated
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.totalStaked, 0.01 ether);
        
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
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(
            keccak256(abi.encodePacked(uint256(42), uint256(123))),
            0.01 ether,
            50
        );
        
        vm.startPrank(guesser);
        
        vm.expectRevert(IGuessGame.InsufficientStake.selector);
        game.submitGuess{value: 0.005 ether}(puzzleId, 50);
        
        vm.stopPrank();
    }
    
    // Note: Testing respondToChallenge requires valid ZK proofs
    // which would be generated off-chain. For unit tests, we can
    // test the access control and state transitions with mock proofs
    // that will fail verification.
    
    function test_RespondToChallenge_OnlyCreator() public {
        // Create puzzle and submit guess
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(
            keccak256(abi.encodePacked(uint256(42), uint256(123))),
            0.01 ether,
            50
        );
        
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 50);
        
        // Try to respond as non-creator
        vm.startPrank(guesser);
        
        uint[2] memory pA = [uint(0), uint(0)];
        uint[2][2] memory pB = [[uint(0), uint(0)], [uint(0), uint(0)]];
        uint[2] memory pC = [uint(0), uint(0)];
        uint[2] memory pubSignals = [uint(0), uint(0)];
        
        vm.expectRevert(IGuessGame.OnlyPuzzleCreator.selector);
        game.respondToChallenge(challengeId, pA, pB, pC, pubSignals);
        
        vm.stopPrank();
    }
    
    function test_ClosePuzzle_WithAccumulatedRewards() public {
        // Create puzzle
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.1 ether}(
            bytes32(uint256(1)),
            0.01 ether,
            50 // 50% growth
        );
        
        // Submit two incorrect guesses
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);
        
        address thirdGuesser = makeAddr("thirdGuesser");
        vm.deal(thirdGuesser, 10 ether);
        vm.prank(thirdGuesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 99);
        
        // Check creator balance before closing
        uint256 creatorBalanceBefore = creator.balance;
        
        // Close puzzle as creator
        vm.prank(creator);
        game.closePuzzle(puzzleId);
        
        // Creator should receive initial bounty + all stakes
        uint256 expectedAmount = 0.1 ether + 0.02 ether; // bounty + totalStaked
        assertEq(creator.balance, creatorBalanceBefore + expectedAmount);
        
        // Verify puzzle is deleted
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        assertEq(puzzle.creator, address(0));
    }
}