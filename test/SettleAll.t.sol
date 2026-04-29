// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import "../src/Rewards.sol";
import "../src/interfaces/IGuessGame.sol";
import "../src/interfaces/ISettleable.sol";
import {AlwaysAcceptVerifier} from "./mocks/AlwaysAcceptVerifier.sol";

contract SettleAllTest is Test {
    GuessGame public game;
    AlwaysAcceptVerifier public verifier;
    Rewards public treasury;
    ERC1967Proxy public proxy;

    address owner;
    address creator;
    address guesser;
    address guesser2;

    bytes32 commitment;

    uint256[2] pA = [uint256(1), uint256(1)];
    uint256[2][2] pB = [[uint256(1), uint256(1)], [uint256(1), uint256(1)]];
    uint256[2] pC = [uint256(1), uint256(1)];

    function setUp() public {
        owner = makeAddr("owner");
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        guesser2 = makeAddr("guesser2");

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

    function _correctSig(uint256 puzzleId, address guesserAddr) internal view returns (uint256[6] memory) {
        return [uint256(uint256(commitment)), 1, 42, 100, puzzleId, uint256(uint160(guesserAddr))];
    }

    function _incorrectSig(uint256 puzzleId, address guesserAddr) internal view returns (uint256[6] memory) {
        return [uint256(uint256(commitment)), 0, 50, 100, puzzleId, uint256(uint160(guesserAddr))];
    }

    /// @dev Drive a single puzzle to a terminal solved state and pause. Creator ends with
    ///      0.5 ether credited to balances; guesser receives bounty + stake immediately.
    function _solvedAndPaused() internal returns (uint256 puzzleId) {
        vm.prank(creator);
        puzzleId = game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        vm.prank(creator);
        game.respondToChallenge(puzzleId, challengeId, pA, pB, pC, _correctSig(puzzleId, guesser));

        vm.prank(owner);
        game.pause();
    }

    /// @dev Drive a forfeited puzzle past CLAIM_TIMEOUT and pause.
    function _forfeitedPaused(address[] memory guessers, uint256[] memory stakes, uint256 bounty)
        internal
        returns (uint256 puzzleId)
    {
        require(guessers.length == stakes.length, "len");

        vm.prank(creator);
        puzzleId = game.createPuzzle{value: bounty}(commitment, bounty, 0.001 ether, 100);

        for (uint256 i; i < guessers.length; i++) {
            vm.prank(guessers[i]);
            game.submitGuess{value: stakes[i]}(puzzleId, i + 1);
        }

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);

        vm.warp(block.timestamp + game.CLAIM_TIMEOUT() + 1);

        // Freeze forfeit accounting via sweep — required by canSettle for forfeited puzzles.
        // (Equivalently every guesser could call claimFromForfeited; sweep is one-call.)
        game.sweepStaleBounty(puzzleId);

        vm.prank(owner);
        game.pause();
    }

    // ============ canSettle ============

    function test_canSettle_falseWhenNotPaused() public {
        _solvedAndPaused();
        // Recreate scenario without pause; un-paused state is the default until pause()
        GuessGame fresh = _freshGame();
        vm.prank(creator);
        fresh.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);
        assertEq(fresh.canSettle(), false);
    }

    function test_canSettle_falseWhenLivePuzzle() public {
        GuessGame fresh = _freshGame();
        vm.prank(creator);
        fresh.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);
        vm.prank(owner);
        fresh.pause();
        assertEq(fresh.canSettle(), false);
    }

    function test_canSettle_falseWhenForfeitClaimWindowOpen() public {
        GuessGame fresh = _freshGame();

        vm.prank(creator);
        uint256 puzzleId = fresh.createPuzzle{value: 0.5 ether}(commitment, 0.0001 ether, 0.001 ether, 100);
        vm.prank(guesser);
        fresh.submitGuess{value: 0.001 ether}(puzzleId, 1);
        vm.warp(block.timestamp + fresh.RESPONSE_TIMEOUT() + 1);
        fresh.forfeitPuzzle(puzzleId, 0);

        vm.prank(owner);
        fresh.pause();

        // forfeitedAt + CLAIM_TIMEOUT not elapsed yet
        assertEq(fresh.canSettle(), false);

        vm.warp(block.timestamp + fresh.CLAIM_TIMEOUT() + 1);

        // Window elapsed but accounting still mutable (challengesClaimed == 0 < pendingAtForfeit == 1)
        assertEq(fresh.canSettle(), false, "canSettle must be false until forfeit accounting is frozen");

        // Freeze accounting via sweepStaleBounty (sets challengesClaimed = pendingAtForfeit).
        // Could also call claimFromForfeited from every guesser; sweep is the simpler path here.
        fresh.sweepStaleBounty(puzzleId);
        assertEq(fresh.canSettle(), true);
    }

    function test_canSettle_trueAfterAllConditions() public {
        _solvedAndPaused();
        assertEq(game.canSettle(), true);
    }

    // ============ settleNext ============

    function test_settleNext_revertsWhenCanSettleFalse() public {
        // Live puzzle, not paused
        vm.prank(creator);
        game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);
        vm.prank(owner);
        vm.expectRevert(ISettleable.CannotSettle.selector);
        game.settleNext(10, "test");
    }

    function test_settleNext_advancesCursor() public {
        _solvedAndPaused();

        uint256 queueLen = game.potentiallyOwedCount();
        assertGt(queueLen, 0);

        vm.prank(owner);
        game.settleNext(queueLen, "test");

        assertEq(game.settleCursor(), queueLen);
    }

    function test_settleNext_paysOwedAddresses() public {
        _solvedAndPaused();

        uint256 creatorBalanceBefore = creator.balance;
        uint256 n = game.potentiallyOwedCount();

        vm.prank(owner);
        game.settleNext(n, "pay-creator");

        // Creator was owed 0.5 ether (collateral); now drained.
        assertEq(creator.balance, creatorBalanceBefore + 0.5 ether);
    }

    function test_settleNext_skipsAlreadyPaid() public {
        _solvedAndPaused();

        uint256 queueLen = game.potentiallyOwedCount();

        vm.prank(owner);
        game.settleNext(queueLen, "first");
        uint256 cursorAfterFirst = game.settleCursor();
        uint256 creatorBalanceAfter = creator.balance;

        // Cannot call again past the queue end
        vm.prank(owner);
        vm.expectRevert(ISettleable.CursorBeyondQueue.selector);
        game.settleNext(1, "second");

        assertEq(game.settleCursor(), cursorAfterFirst);
        assertEq(creator.balance, creatorBalanceAfter);
    }

    function test_settleNext_partialBatch() public {
        // Two-puzzle scenario so multiple addresses get queued
        vm.prank(creator);
        uint256 p1 = game.createPuzzle{value: 0.5 ether}(commitment, 0.4 ether, 0.001 ether, 100);
        vm.prank(creator);
        uint256 p2 = game.createPuzzle{value: 0.5 ether}(commitment, 0.4 ether, 0.001 ether, 100);
        vm.prank(guesser);
        uint256 c1 = game.submitGuess{value: 0.001 ether}(p1, 42);
        vm.prank(creator);
        game.respondToChallenge(p1, c1, pA, pB, pC, _correctSig(p1, guesser));
        vm.prank(guesser2);
        uint256 c2 = game.submitGuess{value: 0.001 ether}(p2, 42);
        vm.prank(creator);
        game.respondToChallenge(p2, c2, pA, pB, pC, _correctSig(p2, guesser2));

        vm.prank(owner);
        game.pause();

        // queue has at least creator + guesser + guesser2 (auto-registered)
        uint256 total = game.potentiallyOwedCount();
        assertGe(total, 3);

        vm.prank(owner);
        game.settleNext(2, "batch-1");
        assertEq(game.settleCursor(), 2);

        vm.prank(owner);
        game.settleNext(total - 2, "batch-2");
        assertEq(game.settleCursor(), total);
    }

    // ============ settleAll ============

    function test_settleAll_revertsBeforeCursorReachesEnd() public {
        _solvedAndPaused();
        vm.prank(owner);
        vm.expectRevert(ISettleable.CursorBehindQueue.selector);
        game.settleAll("too-early");
    }

    function test_settleAll_finalizesAndRenouncesOwnership() public {
        _solvedAndPaused();
        uint256 n = game.potentiallyOwedCount();
        vm.prank(owner);
        game.settleNext(n, "drain");
        vm.prank(owner);
        game.settleAll("done");

        assertEq(game.settled(), true);
        assertEq(game.owner(), address(0));
    }

    function test_settleAll_endToEndForfeitFlowDrainsContract() public {
        // End-to-end forfeit-path settlement: forfeit → sweep (freezes accounting) →
        // settleNext (pays stakes) → settleAll (finalizes; dust must be ≤ MAX_DUST).
        address[] memory guessers = new address[](3);
        guessers[0] = makeAddr("g1");
        guessers[1] = makeAddr("g2");
        guessers[2] = makeAddr("g3");
        for (uint256 i; i < 3; i++) {
            vm.deal(guessers[i], 1 ether);
        }
        uint256[] memory stakes = new uint256[](3);
        stakes[0] = stakes[1] = stakes[2] = 0.001 ether;

        _forfeitedPaused(guessers, stakes, 0.0001 ether);

        // _forfeitedPaused already swept the unclaimed bounty to treasury.
        assertEq(address(treasury).balance, 0.0001 ether, "bounty swept to treasury before pause");
        // Stakes (3 * 0.001 = 0.003 ether) remain on the contract until settleNext.
        assertEq(address(proxy).balance, 0.003 ether, "only stakes remain post-sweep");

        uint256 total = game.potentiallyOwedCount();
        vm.prank(owner);
        game.settleNext(total, "drain");

        // settleNext paid stakes back to guessers.
        assertEq(address(proxy).balance, 0, "stakes paid out");

        vm.prank(owner);
        game.settleAll("final");

        assertEq(address(proxy).balance, 0, "fully drained - no residual");
        // Treasury still holds the original swept bounty; settleAll's dust sweep was 0.
        assertEq(address(treasury).balance, 0.0001 ether);
    }

    function test_settleAll_emitsSettled() public {
        _solvedAndPaused();
        uint256 n = game.potentiallyOwedCount();
        vm.prank(owner);
        game.settleNext(n, "drain");

        vm.expectEmit(true, false, false, false, address(game));
        emit ISettleable.Settled(owner, 0, 0, "done"); // exact amounts/cursor not asserted via this overload
        vm.prank(owner);
        game.settleAll("done");
    }

    // ============ helpers ============

    function _freshGame() internal returns (GuessGame g) {
        AlwaysAcceptVerifier v = new AlwaysAcceptVerifier();
        Rewards t = new Rewards(owner);
        GuessGame impl = new GuessGame();
        bytes memory initData = abi.encodeCall(GuessGame.initialize, (address(v), address(t), owner));
        ERC1967Proxy p = new ERC1967Proxy(address(impl), initData);
        g = GuessGame(address(p));
    }
}
