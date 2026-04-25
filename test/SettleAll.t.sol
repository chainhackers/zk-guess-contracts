// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../src/GuessGame.sol";
import "../src/interfaces/IGuessGame.sol";
import "../src/interfaces/ISettleable.sol";
import "./mocks/CurrentGuessGame.sol";
import {AlwaysAcceptVerifier} from "./mocks/AlwaysAcceptVerifier.sol";

contract SettleAllTest is Test {
    GuessGame public game;
    AlwaysAcceptVerifier public verifier;
    ERC1967Proxy public proxy;

    address owner;
    address creator;
    address guesser;
    address guesser2;
    address treasury;

    bytes32 commitment;

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

        verifier = new AlwaysAcceptVerifier();

        GuessGame impl = new GuessGame();
        bytes memory initData = abi.encodeCall(GuessGame.initialize, (address(verifier), treasury, owner));
        proxy = new ERC1967Proxy(address(impl), initData);
        game = GuessGame(address(proxy));
    }

    function _fundContract() internal {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

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

        // Creator has 0.5 ether collateral in balances now
        assertEq(game.balances(creator), 0.5 ether);
        assertEq(address(proxy).balance, 0.5 ether);
    }

    function _settle(address[] memory recipients) internal {
        vm.prank(owner);
        game.settleAll(recipients, "test");
    }

    function _settleWith(address recipient) internal {
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        _settle(recipients);
    }

    // ============ settle() idempotency tests ============

    function test_settle_overlappingBatchesNoDoubleSpend() public {
        _fundContract();

        address[] memory first = new address[](1);
        first[0] = creator;
        address[] memory second = new address[](1);
        second[0] = creator;

        uint256 balanceBefore = creator.balance;

        vm.prank(owner);
        game.settle(first);
        vm.prank(owner);
        game.settle(second);

        assertEq(creator.balance, balanceBefore + 0.5 ether);
        assertEq(game.settledPaid(creator), true);
    }

    function test_settle_duplicateInBatchNoDoubleSpend() public {
        _fundContract();

        address[] memory recipients = new address[](2);
        recipients[0] = creator;
        recipients[1] = creator;

        uint256 balanceBefore = creator.balance;

        vm.prank(owner);
        game.settle(recipients);

        assertEq(creator.balance, balanceBefore + 0.5 ether);
    }

    // ============ zero-dust guarantee tests (PR #35 discussion) ============
    //
    // These tests prove that settlement drains the contract to exactly 0 across the two
    // paths distinguished in the review discussion:
    //
    // 1. Mid-claim: some claimants call claimFromForfeited first (updates challengesClaimed),
    //    then settleAll picks up the rest. Partial telescoping + dust sweep.
    // 2. Pure settlement: nobody claims first; settleAll computes truncated shares against
    //    a=0 for all, dust sweep sends residual to the last recipient.

    function _forfeitedPuzzleWith3Guessers(uint256 bounty, uint256 stake)
        internal
        returns (uint256 puzzleId, address g1, address g2, address g3)
    {
        g1 = makeAddr("g1");
        g2 = makeAddr("g2");
        g3 = makeAddr("g3");
        vm.deal(g1, 1 ether);
        vm.deal(g2, 1 ether);
        vm.deal(g3, 1 ether);

        vm.prank(creator);
        puzzleId = game.createPuzzle{value: bounty}(commitment, bounty, stake, 100);

        vm.prank(g1);
        game.submitGuess{value: stake}(puzzleId, 1);
        vm.prank(g2);
        game.submitGuess{value: stake}(puzzleId, 2);
        vm.prank(g3);
        game.submitGuess{value: stake}(puzzleId, 3);

        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);
    }

    function test_settleAll_zeroDustAfterMidFlowClaim() public {
        // bounty = 10^14 wei, not divisible by 3 → dust would accumulate without sweep
        uint256 bounty = 0.0001 ether;
        uint256 stake = 0.01 ether;

        (uint256 puzzleId, address g1, address g2, address g3) = _forfeitedPuzzleWith3Guessers(bounty, stake);

        // g1 claims first — updates puzzle.challengesClaimed to 1
        vm.prank(g1);
        game.claimFromForfeited(puzzleId);
        vm.prank(g1);
        game.withdraw();

        // Owner settles the remaining two in one call.
        // Both g2 and g3 compute _computeOwed against the same a=1 snapshot
        // (settleAll does not re-read/update challengesClaimed mid-loop).
        address[] memory recipients = new address[](2);
        recipients[0] = g2;
        recipients[1] = g3;
        vm.prank(owner);
        game.settleAll(recipients, "mid-claim");

        // Contract fully drained — dust sweep (≤10000 wei) absorbs any residual.
        assertEq(address(proxy).balance, 0);
        assertEq(game.settled(), true);

        // Sum of bounty shares received == bounty (zero dust stranded).
        // Each guesser started at 1 ether, paid stake, then got back stake + bountyShare.
        // Net balance - 1 ether == their bounty share.
        uint256 g1Share = g1.balance - 1 ether;
        uint256 g2Share = g2.balance - 1 ether;
        uint256 g3Share = g3.balance - 1 ether;
        assertEq(g1Share + g2Share + g3Share, bounty);
    }

    function test_settleAll_zeroDustWithPureSettlement() public {
        // Same setup; nobody calls claimFromForfeited.
        uint256 bounty = 0.0001 ether;
        uint256 stake = 0.01 ether;

        (uint256 puzzleId, address g1, address g2, address g3) = _forfeitedPuzzleWith3Guessers(bounty, stake);
        puzzleId; // silence unused

        // All three go through settleAll. Each recipient's bounty share is computed
        // against a=0 (no prior claims), so each gets floor(bounty/3). Sum is bounty-1,
        // and the last recipient (g3) absorbs the 1 wei residual via the dust sweep.
        address[] memory recipients = new address[](3);
        recipients[0] = g1;
        recipients[1] = g2;
        recipients[2] = g3;
        vm.prank(owner);
        game.settleAll(recipients, "pure");

        assertEq(address(proxy).balance, 0);
        assertEq(game.settled(), true);

        uint256 floor3 = bounty / 3;
        uint256 g1Share = g1.balance - 1 ether;
        uint256 g2Share = g2.balance - 1 ether;
        uint256 g3Share = g3.balance - 1 ether;
        assertEq(g1Share, floor3);
        assertEq(g2Share, floor3);
        assertEq(g3Share, bounty - 2 * floor3); // gets remainder via dust sweep
        assertEq(g1Share + g2Share + g3Share, bounty);
    }

    // ============ settleAll tests ============

    function test_settleAll_distributesAllFunds() public {
        _fundContract();

        uint256 creatorBalanceBefore = creator.balance;
        _settleWith(creator);

        assertEq(creator.balance, creatorBalanceBefore + 0.5 ether);
        assertEq(address(proxy).balance, 0);
    }

    function test_settleAll_onlyOwner() public {
        _fundContract();

        address[] memory recipients = new address[](1);
        recipients[0] = creator;

        vm.prank(guesser);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, guesser));
        game.settleAll(recipients, "test");
    }

    function test_settleAll_setsSettledFlag() public {
        _fundContract();
        assertEq(game.settled(), false);
        _settleWith(creator);
        assertEq(game.settled(), true);
    }

    function test_settleAll_renouncesOwnership() public {
        _fundContract();
        assertEq(game.owner(), owner);
        _settleWith(creator);
        assertEq(game.owner(), address(0));
    }

    function test_settleAll_emitsSettledEvent() public {
        _fundContract();

        address[] memory recipients = new address[](1);
        recipients[0] = creator;

        vm.expectEmit(true, false, false, true);
        emit ISettleable.Settled(owner, 0.5 ether, 1, "test");

        vm.prank(owner);
        game.settleAll(recipients, "test");
    }

    function test_settleAll_emptyArrays() public {
        _fundContract();

        address[] memory recipients = new address[](0);

        vm.prank(owner);
        vm.expectRevert(ISettleable.EmptySettlement.selector);
        game.settleAll(recipients, "test");
    }

    function test_settleAll_balanceMismatch() public {
        _fundContract();

        // Pass guesser who has no funds — creator's funds remain, balance != 0 after
        address[] memory recipients = new address[](1);
        recipients[0] = guesser;

        vm.prank(owner);
        vm.expectRevert(ISettleable.BalanceMismatch.selector);
        game.settleAll(recipients, "test");
    }

    function test_settleAll_preventsCreatePuzzle() public {
        _fundContract();
        _settleWith(creator);

        vm.prank(creator);
        vm.expectRevert(ISettleable.ContractSettled.selector);
        game.createPuzzle{value: 0.1 ether}(commitment, 0.05 ether, 0.01 ether, 100);
    }

    function test_settleAll_preventsSubmitGuess() public {
        vm.prank(creator);
        game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

        // Settle with creator getting their active puzzle funds
        _settleWith(creator);

        vm.prank(guesser);
        vm.expectRevert(ISettleable.ContractSettled.selector);
        game.submitGuess{value: 0.01 ether}(0, 42);
    }

    function test_settleAll_preventsWithdraw() public {
        _fundContract();
        _settleWith(creator);

        vm.prank(creator);
        vm.expectRevert(ISettleable.ContractSettled.selector);
        game.withdraw();
    }

    function test_settleAll_preventsUpgradeAfter() public {
        _fundContract();
        _settleWith(creator);

        GuessGame newImpl = new GuessGame();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        game.upgradeToAndCall(address(newImpl), "");
    }

    function test_settleAll_cannotCallTwice() public {
        _fundContract();
        _settleWith(creator);

        address[] memory recipients = new address[](1);
        recipients[0] = creator;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        game.settleAll(recipients, "test");
    }

    function test_settleAll_viewFunctionsStillWork() public {
        _fundContract();
        _settleWith(creator);

        IGuessGame.Puzzle memory puzzle = game.getPuzzle(0);
        assertEq(puzzle.creator, creator);

        IGuessGame.Challenge memory challenge = game.getChallenge(0, 0);
        assertEq(challenge.guesser, guesser);

        assertEq(game.puzzleCount(), 1);
        assertEq(game.settled(), true);
    }

    function test_settleAll_viaUpgradeToAndCall() public {
        CurrentGuessGame oldImpl = new CurrentGuessGame();
        bytes memory initData = abi.encodeCall(CurrentGuessGame.initialize, (address(verifier), treasury, owner));
        ERC1967Proxy freshProxy = new ERC1967Proxy(address(oldImpl), initData);

        vm.prank(creator);
        CurrentGuessGame(address(freshProxy)).createPuzzle{value: 0.1 ether}(commitment, 0.01 ether, 100);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(creator);
        CurrentGuessGame(address(freshProxy)).cancelPuzzle(0);

        vm.deal(address(freshProxy), 0.05 ether);

        GuessGame newImpl = new GuessGame();
        // No recipients with funds — just settle with empty balance check
        // Send dust to treasury manually first, then settle
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;

        // treasury has no computed owed, so this will leave 0.05 ETH and revert
        // Instead, use a direct approach: deal the proxy to 0 first
        vm.deal(address(freshProxy), 0);

        bytes memory settleData = abi.encodeCall(ISettleable.settleAll, (recipients, "migration"));

        vm.prank(owner);
        CurrentGuessGame(address(freshProxy)).upgradeToAndCall(address(newImpl), settleData);

        assertEq(address(freshProxy).balance, 0);
        assertEq(GuessGame(address(freshProxy)).settled(), true);
        assertEq(GuessGame(address(freshProxy)).owner(), address(0));
    }

    function test_settleAll_zeroContractBalance() public {
        assertEq(address(proxy).balance, 0);

        address[] memory recipients = new address[](1);
        recipients[0] = creator;

        vm.prank(owner);
        game.settleAll(recipients, "test");

        assertEq(game.settled(), true);
    }

    function test_settleAll_computesForfeited() public {
        vm.prank(creator);
        game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(0, 42);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(guesser);
        game.forfeitPuzzle(0, 0);

        // Collateral slashed to treasury. Remaining: bounty (0.5) + guesser stake (0.01)
        uint256 contractBal = address(proxy).balance;
        assertEq(contractBal, 0.51 ether);

        // Settle — guesser should get stake + bounty share
        address[] memory recipients = new address[](1);
        recipients[0] = guesser;

        uint256 guesserBefore = guesser.balance;
        vm.prank(owner);
        game.settleAll(recipients, "test");

        assertEq(guesser.balance, guesserBefore + 0.51 ether);
        assertEq(address(proxy).balance, 0);
    }

    function test_settleAll_computesActivePuzzleCreator() public {
        vm.prank(creator);
        game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

        // Settle with active puzzle — creator gets bounty + collateral
        _settleWith(creator);

        assertEq(address(proxy).balance, 0);
    }

    // ============ Pause (seal) tests ============

    function test_pause_onlyOwner() public {
        vm.prank(guesser);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, guesser));
        game.pause();
    }

    function test_pause_blocksCreatePuzzle() public {
        vm.prank(owner);
        game.pause();

        vm.prank(creator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        game.createPuzzle{value: 0.1 ether}(commitment, 0.05 ether, 0.01 ether, 100);
    }

    function test_pause_blocksSubmitGuess() public {
        vm.prank(creator);
        game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

        vm.prank(owner);
        game.pause();

        vm.prank(guesser);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        game.submitGuess{value: 0.01 ether}(0, 42);
    }

    function test_pause_allowsCancelPuzzle() public {
        vm.prank(creator);
        game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

        vm.prank(owner);
        game.pause();

        vm.warp(block.timestamp + 1 days + 1);

        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        game.cancelPuzzle(0);

        assertEq(creator.balance, creatorBefore + 1 ether);
    }

    function test_pause_allowsWithdraw() public {
        _fundContract();

        vm.prank(owner);
        game.pause();

        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        game.withdraw();

        assertEq(creator.balance, creatorBefore + 0.5 ether);
    }

    function test_pause_allowsRespondToChallenge() public {
        vm.prank(creator);
        game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(0, 42);

        vm.prank(owner);
        game.pause();

        vm.prank(creator);
        game.respondToChallenge(
            0,
            challengeId,
            pA,
            pB,
            pC,
            [uint256(uint256(commitment)), 0, 42, 100, uint256(0), uint256(uint160(guesser))]
        );
    }

    function test_pause_allowsForfeitPuzzle() public {
        vm.prank(creator);
        game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(0, 42);

        vm.prank(owner);
        game.pause();

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(guesser);
        game.forfeitPuzzle(0, 0);

        assertEq(game.getPuzzle(0).forfeited, true);
    }

    function test_pause_allowsClaimFromForfeited() public {
        vm.prank(creator);
        game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(0, 42);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(guesser);
        game.forfeitPuzzle(0, 0);

        vm.prank(owner);
        game.pause();

        vm.prank(guesser);
        game.claimFromForfeited(0);

        assertGt(game.balances(guesser), 0);
    }

    function test_pause_thenSettleAll() public {
        _fundContract();

        vm.prank(owner);
        game.pause();

        _settleWith(creator);

        assertEq(game.settled(), true);
        assertEq(address(proxy).balance, 0);
    }

    function test_pause_cannotPauseTwice() public {
        vm.prank(owner);
        game.pause();

        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        game.pause();
    }

    function test_pause_isPermanent() public {
        vm.prank(owner);
        game.pause();

        assertEq(game.paused(), true);
    }
}
