// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import "../src/interfaces/IGuessGame.sol";
import "./mocks/OldGuessGame.sol";

/// @title MockVerifier
/// @notice Mock verifier for testing - always returns true
contract MockVerifier {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

/// @title UpgradeCompatibilityTest
/// @notice Tests upgrade from OldGuessGame (commit e6bc579) to new GuessGame
/// @dev Contract deployed but unused scenario - no existing puzzles
contract UpgradeCompatibilityTest is Test {
    OldGuessGame public oldImpl;
    GuessGame public newImpl;
    MockVerifier public verifier;
    ERC1967Proxy public proxy;

    address owner;
    address creator;
    address guesser;
    address treasury;

    function setUp() public {
        owner = makeAddr("owner");
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        treasury = makeAddr("treasury");

        vm.deal(creator, 10 ether);
        vm.deal(guesser, 10 ether);

        // Deploy mock verifier
        verifier = new MockVerifier();

        // Deploy OLD implementation via proxy
        oldImpl = new OldGuessGame();
        bytes memory initData = abi.encodeCall(OldGuessGame.initialize, (address(verifier), treasury, owner));
        proxy = new ERC1967Proxy(address(oldImpl), initData);
    }

    function test_UpgradePreservesState() public {
        // Access old implementation through proxy
        OldGuessGame oldGame = OldGuessGame(address(proxy));

        // Verify initial state on old implementation
        assertEq(address(oldGame.verifier()), address(verifier));
        assertEq(oldGame.treasury(), treasury);
        assertEq(oldGame.puzzleCount(), 0);
        assertEq(oldGame.owner(), owner);

        // Deploy new implementation and upgrade
        newImpl = new GuessGame();
        vm.prank(owner);
        oldGame.upgradeToAndCall(address(newImpl), "");

        // Access new implementation through proxy
        GuessGame newGame = GuessGame(address(proxy));

        // Verify state preserved after upgrade
        assertEq(address(newGame.verifier()), address(verifier));
        assertEq(newGame.treasury(), treasury);
        assertEq(newGame.puzzleCount(), 0);
        assertEq(newGame.owner(), owner);
    }

    function test_NewPuzzleAfterUpgrade() public {
        // Upgrade to new implementation
        OldGuessGame oldGame = OldGuessGame(address(proxy));
        newImpl = new GuessGame();
        vm.prank(owner);
        oldGame.upgradeToAndCall(address(newImpl), "");

        GuessGame newGame = GuessGame(address(proxy));

        // Verify new MIN_BOUNTY constant
        assertEq(newGame.MIN_BOUNTY(), 0.0001 ether);

        // Create puzzle with new MIN_BOUNTY (0.0001 ether) - should succeed
        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));
        vm.prank(creator);
        uint256 puzzleId = newGame.createPuzzle{value: 0.0001 ether}(commitment, 0.0001 ether, 0.00001 ether, 100);

        assertEq(puzzleId, 0);
        assertEq(newGame.puzzleCount(), 1);

        IGuessGame.Puzzle memory puzzle = newGame.getPuzzle(puzzleId);
        assertEq(puzzle.creator, creator);
        assertEq(puzzle.bounty, 0.0001 ether); // Fixed bounty = MIN_BOUNTY
        assertEq(puzzle.collateral, 0); // No extra collateral
        assertEq(puzzle.commitment, commitment);
        assertEq(puzzle.maxNumber, 100);
        assertEq(puzzle.lastResponseTime, 0);
    }

    function test_NewPuzzleOptionalCollateral() public {
        // Upgrade to new implementation
        OldGuessGame oldGame = OldGuessGame(address(proxy));
        newImpl = new GuessGame();
        vm.prank(owner);
        oldGame.upgradeToAndCall(address(newImpl), "");

        GuessGame newGame = GuessGame(address(proxy));

        // Create puzzle with optional collateral (0.1 ether total)
        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));
        vm.prank(creator);
        uint256 puzzleId = newGame.createPuzzle{value: 0.1 ether}(commitment, 0.0001 ether, 0.01 ether, 100);

        IGuessGame.Puzzle memory puzzle = newGame.getPuzzle(puzzleId);

        // Verify new bounty/collateral split
        assertEq(puzzle.bounty, 0.0001 ether); // Fixed bounty = MIN_BOUNTY
        assertEq(puzzle.collateral, 0.0999 ether); // msg.value - MIN_BOUNTY
    }

    function test_FullGameFlowAfterUpgrade() public {
        // Upgrade to new implementation
        OldGuessGame oldGame = OldGuessGame(address(proxy));
        newImpl = new GuessGame();
        vm.prank(owner);
        oldGame.upgradeToAndCall(address(newImpl), "");

        GuessGame newGame = GuessGame(address(proxy));

        // Create puzzle
        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));
        vm.prank(creator);
        uint256 puzzleId = newGame.createPuzzle{value: 0.1 ether}(commitment, 0.0001 ether, 0.01 ether, 100);

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = newGame.submitGuess{value: 0.01 ether}(puzzleId, 42);

        IGuessGame.Puzzle memory puzzleBefore = newGame.getPuzzle(puzzleId);
        assertEq(puzzleBefore.pendingChallenges, 1);
        assertEq(puzzleBefore.lastResponseTime, 0);

        // Record balances before response
        uint256 guesserBalanceBefore = guesser.balance;

        // Respond with correct guess (mock verifier returns true)
        // pubSignals: [commitment, isCorrect=1, guess=42, maxNumber=100]
        uint256[2] memory pA = [uint256(1), uint256(1)];
        uint256[2][2] memory pB = [[uint256(1), uint256(1)], [uint256(1), uint256(1)]];
        uint256[2] memory pC = [uint256(1), uint256(1)];
        uint256[4] memory pubSignals = [uint256(uint256(commitment)), 1, 42, 100];

        vm.prank(creator);
        newGame.respondToChallenge(puzzleId, challengeId, pA, pB, pC, pubSignals);

        // Verify puzzle solved
        IGuessGame.Puzzle memory puzzleAfter = newGame.getPuzzle(puzzleId);
        assertEq(puzzleAfter.solved, true);
        assertEq(puzzleAfter.pendingChallenges, 0);
        assertEq(puzzleAfter.lastResponseTime, block.timestamp);

        // Verify payout: guesser gets bounty + stake back
        uint256 expectedPrize = 0.0001 ether + 0.01 ether; // bounty + stake
        assertEq(guesser.balance, guesserBalanceBefore + expectedPrize);

        // Verify creator's collateral returned to balance
        assertEq(newGame.balances(creator), 0.0999 ether);
    }

    function test_OldMinBountyFailsAfterUpgrade() public {
        // Upgrade to new implementation
        OldGuessGame oldGame = OldGuessGame(address(proxy));
        newImpl = new GuessGame();
        vm.prank(owner);
        oldGame.upgradeToAndCall(address(newImpl), "");

        GuessGame newGame = GuessGame(address(proxy));

        // OLD behavior required MIN_BOUNTY * 2 = 0.002 ether
        // NEW behavior only requires MIN_BOUNTY = 0.0001 ether
        // So OLD minimum (0.001 ether) still works with new
        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));

        // 0.001 ether should work (more than new MIN_BOUNTY)
        vm.prank(creator);
        uint256 puzzleId = newGame.createPuzzle{value: 0.001 ether}(commitment, 0.0001 ether, 0.00001 ether, 100);

        IGuessGame.Puzzle memory puzzle = newGame.getPuzzle(puzzleId);
        assertEq(puzzle.bounty, 0.0001 ether);
        assertEq(puzzle.collateral, 0.0009 ether);
    }

    function test_OldMinBountyInsufficientForOld() public {
        // Test OLD implementation requires 2x MIN_BOUNTY
        OldGuessGame oldGame = OldGuessGame(address(proxy));

        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));

        // OLD MIN_BOUNTY = 0.001 ether, requires at least 0.002 ether
        // 0.001 ether should fail
        vm.prank(creator);
        vm.expectRevert(OldGuessGame.InsufficientBounty.selector);
        oldGame.createPuzzle{value: 0.001 ether}(commitment, 0.00001 ether, 100);

        // 0.002 ether should succeed
        vm.prank(creator);
        uint256 puzzleId = oldGame.createPuzzle{value: 0.002 ether}(commitment, 0.00001 ether, 100);

        OldGuessGame.OldPuzzle memory puzzle = oldGame.getPuzzle(puzzleId);
        // OLD logic: collateral = msg.value / 2, bounty = msg.value - collateral
        assertEq(puzzle.collateral, 0.001 ether);
        assertEq(puzzle.bounty, 0.001 ether);
    }

    function test_IncorrectGuessStakeReturned() public {
        // Upgrade to new implementation
        OldGuessGame oldGame = OldGuessGame(address(proxy));
        newImpl = new GuessGame();
        vm.prank(owner);
        oldGame.upgradeToAndCall(address(newImpl), "");

        GuessGame newGame = GuessGame(address(proxy));

        // Create puzzle
        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));
        vm.prank(creator);
        uint256 puzzleId = newGame.createPuzzle{value: 0.1 ether}(commitment, 0.0001 ether, 0.01 ether, 100);

        // Submit wrong guess
        vm.prank(guesser);
        uint256 challengeId = newGame.submitGuess{value: 0.01 ether}(puzzleId, 50);

        uint256 guesserBalanceBefore = guesser.balance;

        // Respond with incorrect guess
        uint256[2] memory pA = [uint256(1), uint256(1)];
        uint256[2][2] memory pB = [[uint256(1), uint256(1)], [uint256(1), uint256(1)]];
        uint256[2] memory pC = [uint256(1), uint256(1)];
        uint256[4] memory pubSignals = [uint256(uint256(commitment)), 0, 50, 100]; // isCorrect = 0

        vm.prank(creator);
        newGame.respondToChallenge(puzzleId, challengeId, pA, pB, pC, pubSignals);

        // Verify puzzle NOT solved
        IGuessGame.Puzzle memory puzzle = newGame.getPuzzle(puzzleId);
        assertEq(puzzle.solved, false);

        // Verify guesser gets stake back
        assertEq(guesser.balance, guesserBalanceBefore + 0.01 ether);
    }

    function test_LastResponseTimeSetOnResponse() public {
        // Upgrade to new implementation
        OldGuessGame oldGame = OldGuessGame(address(proxy));
        newImpl = new GuessGame();
        vm.prank(owner);
        oldGame.upgradeToAndCall(address(newImpl), "");

        GuessGame newGame = GuessGame(address(proxy));

        // Create puzzle and submit guess
        bytes32 commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));
        vm.prank(creator);
        uint256 puzzleId = newGame.createPuzzle{value: 0.1 ether}(commitment, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = newGame.submitGuess{value: 0.01 ether}(puzzleId, 50);

        // Verify lastResponseTime is 0 before response
        assertEq(newGame.getPuzzle(puzzleId).lastResponseTime, 0);

        // Warp time
        vm.warp(block.timestamp + 1 hours);

        // Respond to challenge
        uint256[2] memory pA = [uint256(1), uint256(1)];
        uint256[2][2] memory pB = [[uint256(1), uint256(1)], [uint256(1), uint256(1)]];
        uint256[2] memory pC = [uint256(1), uint256(1)];
        uint256[4] memory pubSignals = [uint256(uint256(commitment)), 0, 50, 100];

        vm.prank(creator);
        newGame.respondToChallenge(puzzleId, challengeId, pA, pB, pC, pubSignals);

        // Verify lastResponseTime is set
        assertEq(newGame.getPuzzle(puzzleId).lastResponseTime, block.timestamp);
    }

    function test_OnlyOwnerCanUpgrade() public {
        OldGuessGame oldGame = OldGuessGame(address(proxy));
        newImpl = new GuessGame();

        // Non-owner cannot upgrade
        vm.prank(creator);
        vm.expectRevert();
        oldGame.upgradeToAndCall(address(newImpl), "");

        // Owner can upgrade
        vm.prank(owner);
        oldGame.upgradeToAndCall(address(newImpl), "");
    }

    function test_CannotReinitializeAfterUpgrade() public {
        // Upgrade to new implementation
        OldGuessGame oldGame = OldGuessGame(address(proxy));
        newImpl = new GuessGame();
        vm.prank(owner);
        oldGame.upgradeToAndCall(address(newImpl), "");

        GuessGame newGame = GuessGame(address(proxy));

        // Cannot reinitialize
        vm.expectRevert();
        newGame.initialize(address(verifier), treasury, owner);
    }
}
