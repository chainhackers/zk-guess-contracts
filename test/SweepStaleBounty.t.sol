// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import "../src/Rewards.sol";
import "../src/interfaces/IGuessGame.sol";
import {AlwaysAcceptVerifier} from "./mocks/AlwaysAcceptVerifier.sol";

/// @notice C3 — `sweepStaleBounty(puzzleId)` deterministic state machine for unclaimed
/// forfeit bounty after the 90-day claim window closes.
contract SweepStaleBountyTest is Test {
    GuessGame public game;
    Rewards public treasury;
    AlwaysAcceptVerifier public verifier;
    ERC1967Proxy public proxy;

    address owner;
    address creator;
    address guesser;
    address guesser2;
    address sweeper; // permissionless caller
    bytes32 commitment;

    uint256[2] pA = [uint256(1), uint256(1)];
    uint256[2][2] pB = [[uint256(1), uint256(1)], [uint256(1), uint256(1)]];
    uint256[2] pC = [uint256(1), uint256(1)];

    function setUp() public {
        owner = makeAddr("owner");
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        guesser2 = makeAddr("guesser2");
        sweeper = makeAddr("sweeper");

        vm.deal(creator, 10 ether);
        vm.deal(guesser, 10 ether);
        vm.deal(guesser2, 10 ether);

        commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));

        verifier = new AlwaysAcceptVerifier();
        treasury = new Rewards(owner);

        GuessGame impl = new GuessGame();
        bytes memory initData = abi.encodeCall(GuessGame.initialize, (address(verifier), address(treasury), owner));
        proxy = new ERC1967Proxy(address(impl), initData);
        game = GuessGame(address(proxy));
    }

    /// @dev Build a forfeited puzzle with `bountyAmt` bounty and two pending challenges.
    function _forfeitedTwoGuessers(uint256 bountyAmt) internal returns (uint256 puzzleId) {
        vm.prank(creator);
        puzzleId = game.createPuzzle{value: bountyAmt}(commitment, bountyAmt, 0.001 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.001 ether}(puzzleId, 1);
        vm.prank(guesser2);
        game.submitGuess{value: 0.001 ether}(puzzleId, 2);

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);
    }

    function test_sweep_revertsBeforeClaimWindow() public {
        uint256 puzzleId = _forfeitedTwoGuessers(0.0001 ether);

        // 1 second short of the window closing
        vm.warp(block.timestamp + game.CLAIM_TIMEOUT() - 1);

        vm.prank(sweeper);
        vm.expectRevert(IGuessGame.ClaimWindowOpen.selector);
        game.sweepStaleBounty(puzzleId);
    }

    function test_sweep_succeedsAfterClaimWindow() public {
        uint256 bountyAmt = 0.0001 ether;
        uint256 puzzleId = _forfeitedTwoGuessers(bountyAmt);
        uint256 treasuryBefore = address(treasury).balance;

        vm.warp(block.timestamp + game.CLAIM_TIMEOUT() + 1);

        vm.expectEmit(true, false, false, true, address(game));
        emit IGuessGame.StaleBountySwept(puzzleId, bountyAmt);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit Rewards.RewardsFunded(address(game), bountyAmt, "stale-bounty-sweep");

        vm.prank(sweeper);
        game.sweepStaleBounty(puzzleId);

        // Full bounty in treasury (no claims happened).
        assertEq(address(treasury).balance, treasuryBefore + bountyAmt);
    }

    function test_sweep_partialAfterSomeClaimed() public {
        uint256 bountyAmt = 0.0001 ether;
        uint256 puzzleId = _forfeitedTwoGuessers(bountyAmt);

        // Guesser1 claims first — half the bounty + their stake credited to balances.
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);

        uint256 treasuryBefore = address(treasury).balance;
        uint256 expectedSwept = bountyAmt - bountyAmt / 2; // unclaimed remainder (cumulative-divisor)

        vm.warp(block.timestamp + game.CLAIM_TIMEOUT() + 1);

        vm.prank(sweeper);
        game.sweepStaleBounty(puzzleId);

        assertEq(address(treasury).balance, treasuryBefore + expectedSwept);

        // Post-sweep, guesser2 can still claim their *stake* (sweep takes only the unclaimed
        // bounty; stakes are tracked separately and stay claimable indefinitely). Bounty
        // share is now zero.
        uint256 g2BalanceBefore = game.balances(guesser2);
        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId);
        assertEq(game.balances(guesser2), g2BalanceBefore + 0.001 ether); // stake only, no bounty
    }

    /// @notice Regression: post-sweep `claimFromForfeited` (stake-only) must NOT mutate
    ///         `puzzle.challengesClaimed`. Otherwise it would tip past `pendingAtForfeit`
    ///         and break `canSettle`'s frozen-accounting invariant, permanently blocking
    ///         settlement (see PR #43 review comment 3144294311).
    function test_sweep_postSweepClaim_keepsContractSettleable() public {
        uint256 bountyAmt = 0.0001 ether;
        uint256 puzzleId = _forfeitedTwoGuessers(bountyAmt);

        IGuessGame.Puzzle memory pBefore = game.getPuzzle(puzzleId);
        uint256 pendingAtForfeit = pBefore.pendingAtForfeit;

        vm.warp(block.timestamp + game.CLAIM_TIMEOUT() + 1);

        // Sweep first — sets challengesClaimed == pendingAtForfeit, zeros bounty.
        vm.prank(sweeper);
        game.sweepStaleBounty(puzzleId);

        IGuessGame.Puzzle memory pAfterSweep = game.getPuzzle(puzzleId);
        assertEq(pAfterSweep.challengesClaimed, pendingAtForfeit);
        assertEq(pAfterSweep.bounty, 0);

        // Both guessers claim their stake AFTER the sweep — must not touch challengesClaimed.
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);
        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId);

        IGuessGame.Puzzle memory pAfterClaims = game.getPuzzle(puzzleId);
        assertEq(pAfterClaims.challengesClaimed, pendingAtForfeit, "post-sweep claims must not increment");

        // Pause and confirm the contract is still settleable.
        vm.prank(owner);
        game.pause();
        assertTrue(game.canSettle(), "post-sweep stake claims must not break canSettle");
    }

    function test_sweep_revertsOnNothingToSweep() public {
        uint256 bountyAmt = 0.0001 ether;
        uint256 puzzleId = _forfeitedTwoGuessers(bountyAmt);

        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);
        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId);

        vm.warp(block.timestamp + game.CLAIM_TIMEOUT() + 1);

        vm.prank(sweeper);
        vm.expectRevert(IGuessGame.NothingToSweep.selector);
        game.sweepStaleBounty(puzzleId);
    }

    function test_sweep_revertsOnNotForfeited() public {
        // Solved puzzle — never forfeited.
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.5 ether}(commitment, 0.0001 ether, 0.01 ether, 100);
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);
        vm.prank(creator);
        game.respondToChallenge(
            puzzleId,
            challengeId,
            pA,
            pB,
            pC,
            [uint256(uint256(commitment)), 1, 42, 100, puzzleId, uint256(uint160(guesser))]
        );

        vm.warp(block.timestamp + game.CLAIM_TIMEOUT() + 1);

        vm.prank(sweeper);
        vm.expectRevert(IGuessGame.PuzzleNotForfeited.selector);
        game.sweepStaleBounty(puzzleId);
    }

    function test_sweep_revertsOnNotFound() public {
        vm.prank(sweeper);
        vm.expectRevert(IGuessGame.PuzzleNotFound.selector);
        game.sweepStaleBounty(999);
    }

    function test_sweep_isPermissionless() public {
        uint256 puzzleId = _forfeitedTwoGuessers(0.0001 ether);
        vm.warp(block.timestamp + game.CLAIM_TIMEOUT() + 1);

        // Random EOA can sweep — no onlyOwner / onlyCreator gate.
        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        game.sweepStaleBounty(puzzleId);
    }
}
