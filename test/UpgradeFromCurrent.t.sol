// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import "../src/interfaces/IGuessGame.sol";
import "./mocks/CurrentGuessGame.sol";

/// @title MockVerifierCurrent
/// @notice Always-accept mock supporting both v1 ([4]) and v2 ([6]) public-signal shapes,
///         so the same proxy storage slot serves CurrentGuessGame pre-upgrade and the new
///         GuessGame post-upgrade.
contract MockVerifierCurrent {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[6] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

/// @title UpgradeFromCurrentTest
/// @notice Tests upgrade from CurrentGuessGame (3-arg, deployed impl) to new GuessGame (4-arg)
contract UpgradeFromCurrentTest is Test {
    CurrentGuessGame public oldImpl;
    GuessGame public newImpl;
    MockVerifierCurrent public verifier;
    ERC1967Proxy public proxy;

    address owner;
    address creator;
    address guesser;
    address guesser2;
    address treasury;

    bytes32 commitment;

    // Proof dummy values (mock verifier always returns true)
    uint256[2] pA = [uint256(1), uint256(1)];
    uint256[2][2] pB = [[uint256(1), uint256(1)], [uint256(1), uint256(1)]];
    uint256[2] pC = [uint256(1), uint256(1)];

    function setUp() public {
        owner = makeAddr("owner");
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        guesser2 = makeAddr("guesser2");
        treasury = makeAddr("treasury");

        vm.deal(creator, 10 ether);
        vm.deal(guesser, 10 ether);
        vm.deal(guesser2, 10 ether);

        commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));

        verifier = new MockVerifierCurrent();

        // Deploy CurrentGuessGame (3-arg) via proxy
        oldImpl = new CurrentGuessGame();
        bytes memory initData = abi.encodeCall(CurrentGuessGame.initialize, (address(verifier), treasury, owner));
        proxy = new ERC1967Proxy(address(oldImpl), initData);
    }

    function _upgrade() internal returns (GuessGame) {
        newImpl = new GuessGame();
        vm.prank(owner);
        CurrentGuessGame(address(proxy)).upgradeToAndCall(address(newImpl), "");
        return GuessGame(address(proxy));
    }

    function _createOldPuzzle() internal returns (uint256 puzzleId) {
        vm.prank(creator);
        puzzleId = CurrentGuessGame(address(proxy)).createPuzzle{value: 0.1 ether}(commitment, 0.01 ether, 100);
    }

    function _submitOldGuess(uint256 puzzleId, uint256 guess) internal returns (uint256 challengeId) {
        vm.prank(guesser);
        challengeId = CurrentGuessGame(address(proxy)).submitGuess{value: 0.01 ether}(puzzleId, guess);
    }

    function _pubSignals(uint256 guess, uint256 isCorrect) internal view returns (uint256[6] memory) {
        // Both call sites in this file use the first puzzle (id 0) and the default `guesser`
        // address, so hardcoding here keeps the call sites compact.
        return [uint256(uint256(commitment)), isCorrect, guess, 100, 0, uint256(uint160(guesser))];
    }

    /// @notice Upgrade preserves all puzzle state fields
    function test_UpgradePreservesState() public {
        uint256 puzzleId = _createOldPuzzle();

        // Verify old state
        CurrentGuessGame oldGame = CurrentGuessGame(address(proxy));
        CurrentGuessGame.Puzzle memory oldPuzzle = oldGame.getPuzzle(puzzleId);
        assertEq(oldPuzzle.creator, creator);
        assertEq(oldPuzzle.bounty, 0.0001 ether); // MIN_BOUNTY
        assertEq(oldPuzzle.collateral, 0.0999 ether); // msg.value - MIN_BOUNTY
        assertEq(oldPuzzle.stakeRequired, 0.01 ether);
        assertEq(oldPuzzle.maxNumber, 100);
        assertEq(oldPuzzle.lastResponseTime, 0);

        // Upgrade
        GuessGame newGame = _upgrade();

        // Verify state preserved through new interface
        IGuessGame.Puzzle memory newPuzzle = newGame.getPuzzle(puzzleId);
        assertEq(newPuzzle.creator, creator);
        assertEq(newPuzzle.bounty, 0.0001 ether);
        assertEq(newPuzzle.collateral, 0.0999 ether);
        assertEq(newPuzzle.stakeRequired, 0.01 ether);
        assertEq(newPuzzle.maxNumber, 100);
        assertEq(newPuzzle.commitment, commitment);
        assertEq(newPuzzle.solved, false);
        assertEq(newPuzzle.cancelled, false);
        assertEq(newPuzzle.forfeited, false);
        assertEq(newPuzzle.lastResponseTime, 0);
        assertEq(newGame.puzzleCount(), 1);
        assertEq(address(newGame.verifier()), address(verifier));
        assertEq(newGame.treasury(), treasury);
        assertEq(newGame.owner(), owner);
    }

    /// @notice Submit guess on old puzzle after upgrade
    function test_OldPuzzleGuessAfterUpgrade() public {
        uint256 puzzleId = _createOldPuzzle();

        GuessGame newGame = _upgrade();

        // Submit guess via new implementation
        vm.prank(guesser);
        uint256 challengeId = newGame.submitGuess{value: 0.01 ether}(puzzleId, 42);

        assertEq(challengeId, 0);
        IGuessGame.Puzzle memory puzzle = newGame.getPuzzle(puzzleId);
        assertEq(puzzle.pendingChallenges, 1);
        assertEq(puzzle.challengeCount, 1);

        IGuessGame.Challenge memory challenge = newGame.getChallenge(puzzleId, challengeId);
        assertEq(challenge.guesser, guesser);
        assertEq(challenge.guess, 42);
        assertEq(challenge.stake, 0.01 ether);
    }

    /// @notice Respond to old puzzle challenge after upgrade
    function test_OldPuzzleRespondAfterUpgrade() public {
        uint256 puzzleId = _createOldPuzzle();
        uint256 challengeId = _submitOldGuess(puzzleId, 42);

        GuessGame newGame = _upgrade();

        uint256 guesserBalanceBefore = guesser.balance;

        // Respond with correct guess via new implementation
        vm.prank(creator);
        newGame.respondToChallenge(puzzleId, challengeId, pA, pB, pC, _pubSignals(42, 1));

        IGuessGame.Puzzle memory puzzle = newGame.getPuzzle(puzzleId);
        assertEq(puzzle.solved, true);
        assertEq(puzzle.pendingChallenges, 0);
        assertEq(puzzle.lastResponseTime, block.timestamp);

        // Guesser gets bounty + stake
        uint256 expectedPrize = 0.0001 ether + 0.01 ether;
        assertEq(guesser.balance, guesserBalanceBefore + expectedPrize);

        // Creator's collateral returned to balance
        assertEq(newGame.balances(creator), 0.0999 ether);
    }

    /// @notice Forfeit old puzzle + claim after upgrade
    function test_OldPuzzleForfeitAfterUpgrade() public {
        uint256 puzzleId = _createOldPuzzle();
        uint256 challengeId = _submitOldGuess(puzzleId, 42);

        GuessGame newGame = _upgrade();

        // Warp past RESPONSE_TIMEOUT
        vm.warp(block.timestamp + 1 days + 1);

        uint256 treasuryBefore = treasury.balance;

        // Forfeit via new implementation
        vm.prank(guesser);
        newGame.forfeitPuzzle(puzzleId, challengeId);

        IGuessGame.Puzzle memory puzzle = newGame.getPuzzle(puzzleId);
        assertEq(puzzle.forfeited, true);
        assertEq(puzzle.pendingAtForfeit, 1);

        // Collateral slashed to treasury
        assertEq(treasury.balance, treasuryBefore + 0.0999 ether);

        // Claim from forfeited
        vm.prank(guesser);
        newGame.claimFromForfeited(puzzleId);

        // Guesser gets stake + full bounty (sole pending challenge)
        uint256 expectedPayout = 0.01 ether + 0.0001 ether;
        assertEq(newGame.balances(guesser), expectedPayout);

        // Withdraw
        uint256 guesserBalanceBefore = guesser.balance;
        vm.prank(guesser);
        newGame.withdraw();
        assertEq(guesser.balance, guesserBalanceBefore + expectedPayout);
    }

    /// @notice Cancel old puzzle after upgrade
    function test_OldPuzzleCancelAfterUpgrade() public {
        uint256 puzzleId = _createOldPuzzle();

        GuessGame newGame = _upgrade();

        uint256 creatorBalanceBefore = creator.balance;

        // Cancel via new implementation (warp past timeout — old puzzles have lastChallengeTimestamp=0)
        vm.warp(block.timestamp + newGame.CANCEL_TIMEOUT() + 1);
        vm.prank(creator);
        newGame.cancelPuzzle(puzzleId);

        IGuessGame.Puzzle memory puzzle = newGame.getPuzzle(puzzleId);
        assertEq(puzzle.cancelled, true);

        // Creator gets bounty + collateral back
        assertEq(creator.balance, creatorBalanceBefore + 0.1 ether);
    }

    /// @notice Create new puzzle with 4-arg signature after upgrade, full game flow
    function test_NewPuzzleAfterUpgrade() public {
        GuessGame newGame = _upgrade();

        // Create puzzle with new 4-arg signature
        vm.prank(creator);
        uint256 puzzleId = newGame.createPuzzle{value: 0.1 ether}(commitment, 0.05 ether, 0.01 ether, 100);

        IGuessGame.Puzzle memory puzzle = newGame.getPuzzle(puzzleId);
        assertEq(puzzle.bounty, 0.05 ether);
        assertEq(puzzle.collateral, 0.05 ether); // 0.1 - 0.05

        // Submit guess
        vm.prank(guesser);
        uint256 challengeId = newGame.submitGuess{value: 0.01 ether}(puzzleId, 42);

        uint256 guesserBalanceBefore = guesser.balance;

        // Respond with correct guess
        vm.prank(creator);
        newGame.respondToChallenge(puzzleId, challengeId, pA, pB, pC, _pubSignals(42, 1));

        // Puzzle solved
        puzzle = newGame.getPuzzle(puzzleId);
        assertEq(puzzle.solved, true);

        // Guesser gets bounty + stake
        uint256 expectedPrize = 0.05 ether + 0.01 ether;
        assertEq(guesser.balance, guesserBalanceBefore + expectedPrize);

        // Creator's collateral returned
        assertEq(newGame.balances(creator), 0.05 ether);
    }

    /// @notice Create puzzle with custom bounty > MIN_BOUNTY after upgrade
    function test_NewPuzzleCustomBounty() public {
        GuessGame newGame = _upgrade();

        // Custom bounty of 1 ether, with 0.5 ether collateral
        vm.prank(creator);
        uint256 puzzleId = newGame.createPuzzle{value: 1.5 ether}(commitment, 1 ether, 0.01 ether, 100);

        IGuessGame.Puzzle memory puzzle = newGame.getPuzzle(puzzleId);
        assertEq(puzzle.bounty, 1 ether);
        assertEq(puzzle.collateral, 0.5 ether);
        assertEq(puzzle.stakeRequired, 0.01 ether);
        assertEq(puzzle.maxNumber, 100);

        // Verify bounty < MIN_BOUNTY still reverts
        vm.prank(creator);
        vm.expectRevert(IGuessGame.InsufficientBounty.selector);
        newGame.createPuzzle{value: 0.00001 ether}(commitment, 0.00001 ether, 0.00001 ether, 100);

        // Verify msg.value < bounty reverts
        vm.prank(creator);
        vm.expectRevert(IGuessGame.InsufficientDeposit.selector);
        newGame.createPuzzle{value: 0.0001 ether}(commitment, 0.001 ether, 0.00001 ether, 100);
    }
}
