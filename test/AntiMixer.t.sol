// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import {AlwaysAcceptVerifier} from "./mocks/AlwaysAcceptVerifier.sol";
import {RevertingVerifier} from "./mocks/RevertingVerifier.sol";

/// @title NotAMixer
/// @notice Adversarial / threat-model tests that frame the v2 binding errors
///         (`InvalidPuzzleIdBinding`, `InvalidGuesserBinding`) and the broader
///         "this is not a mixer" properties in terms a clustering heuristic — or a
///         human reviewer skimming `forge test --match-contract NotAMixer` — can
///         immediately read.
///
/// The five sections (A–E) correspond to the comparison table in
/// `docs/superpowers/specs/2026-04-23-clean-redeploy-antimixer-design.md` and to
/// the design table at the top of this file. Each test names a property that
/// would pass on a Tornado-class mixer and fail here.
contract NotAMixer is Test {
    AlwaysAcceptVerifier verifier;
    GuessGame game;

    address creator;
    address guesser;
    address guesser2;
    address treasury;

    bytes32 constant COMMITMENT_42_123 = 0x1d869fb8246b6131377493aaaf1cc16a8284d4aedcb7277079df35d0d1d552d1;

    uint256[2] proofA = [uint256(1), uint256(1)];
    uint256[2][2] proofB = [[uint256(1), uint256(1)], [uint256(1), uint256(1)]];
    uint256[2] proofC = [uint256(1), uint256(1)];

    function setUp() public {
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        guesser2 = makeAddr("guesser2");
        treasury = makeAddr("treasury");

        vm.deal(creator, 100 ether);
        vm.deal(guesser, 100 ether);
        vm.deal(guesser2, 100 ether);

        verifier = new AlwaysAcceptVerifier();
        game = _deployGame(address(verifier), treasury);
    }

    function _deployGame(address _verifier, address _treasury) internal returns (GuessGame g) {
        GuessGame impl = new GuessGame();
        bytes memory initData = abi.encodeCall(GuessGame.initialize, (_verifier, _treasury, address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        g = GuessGame(address(proxy));
    }

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

    // =========================================================================
    // A. Cross-puzzle replay rejection (puzzleId binding)
    // =========================================================================

    /// @notice MIXER would: accept a proof against any deposit sharing the secret.
    /// @notice HERE: even when two puzzles share the same commitment, a proof
    ///         minted for puzzle A is rejected on puzzle B.
    function test_NotAMixer_ProofForPuzzleA_RejectedOnPuzzleB_SameCommitment() public {
        // Two puzzles with the IDENTICAL commitment — perfectly legal.
        vm.prank(creator);
        uint256 puzzleA = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);
        vm.prank(creator);
        uint256 puzzleB = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);
        assertTrue(puzzleA != puzzleB, "two distinct puzzleIds");

        vm.prank(guesser);
        uint256 challengeOnA = game.submitGuess{value: 0.01 ether}(puzzleA, 42);

        vm.prank(guesser2);
        uint256 challengeOnB = game.submitGuess{value: 0.01 ether}(puzzleB, 42);

        // Adversary: take a proof minted for puzzle A and try it on puzzle B's challenge.
        // (`pubSignals[5]` is set to challenge-B's guesser so the guesser binding doesn't trip first.)
        uint256[6] memory proofForA = _pubSig(COMMITMENT_42_123, 1, 42, 100, puzzleA, guesser2);

        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidPuzzleIdBinding.selector);
        game.respondToChallenge(puzzleB, challengeOnB, proofA, proofB, proofC, proofForA);

        // Sanity: positive path on puzzle A still works.
        uint256[6] memory proofForAOnA = _pubSig(COMMITMENT_42_123, 1, 42, 100, puzzleA, guesser);
        vm.prank(creator);
        game.respondToChallenge(puzzleA, challengeOnA, proofA, proofB, proofC, proofForAOnA);

        IGuessGame.Puzzle memory pa = game.getPuzzle(puzzleA);
        assertTrue(pa.solved, "puzzle A solved");
        IGuessGame.Puzzle memory pb = game.getPuzzle(puzzleB);
        assertFalse(pb.solved, "puzzle B not solved");
    }

    /// @notice MIXER would: accept any proof tied to the right secret, regardless
    ///         of which deposit it's claiming.
    /// @notice HERE: proof-vs-puzzleId mismatch is checked literally on a single puzzle.
    function test_NotAMixer_ProofPuzzleIdMismatch_RejectedOnSinglePuzzle() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // pubSignals[4] = puzzleId + 1 — bogus binding.
        uint256[6] memory bogus = _pubSig(COMMITMENT_42_123, 1, 42, 100, puzzleId + 1, guesser);

        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidPuzzleIdBinding.selector);
        game.respondToChallenge(puzzleId, challengeId, proofA, proofB, proofC, bogus);
    }

    /// @notice The fail-fast contract: a malformed proof never reaches the verifier
    ///         (saving ~200k gas on the pairing check). Demonstrated by deploying
    ///         a verifier that *always* reverts and showing the binding-check selector
    ///         fires first — the verifier is never called.
    function test_NotAMixer_PuzzleIdBindingChecked_BeforeVerifier() public {
        RevertingVerifier rv = new RevertingVerifier();
        GuessGame g = _deployGame(address(rv), treasury);

        vm.prank(creator);
        uint256 puzzleId = g.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);
        vm.prank(guesser);
        uint256 challengeId = g.submitGuess{value: 0.01 ether}(puzzleId, 42);

        uint256[6] memory bogus = _pubSig(COMMITMENT_42_123, 1, 42, 100, puzzleId + 1, guesser);

        // If verifyProof had run, we'd see VerifierUnreachable. The binding check fires first.
        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidPuzzleIdBinding.selector);
        g.respondToChallenge(puzzleId, challengeId, proofA, proofB, proofC, bogus);
    }

    // =========================================================================
    // B. Recipient binding (guesser binding)
    // =========================================================================

    /// @notice MIXER would: any address holding a valid proof can withdraw.
    /// @notice HERE: a proof minted for guesserA cannot service guesserB's challenge,
    ///         even when the guess matches.
    function test_NotAMixer_ProofForGuesserA_RejectedForGuesserB() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 c1 = game.submitGuess{value: 0.01 ether}(puzzleId, 42);
        vm.prank(guesser2);
        uint256 c2 = game.submitGuess{value: 0.01 ether}(puzzleId, 41);

        // Adversary tries to repurpose guesser1's proof for guesser2's challenge.
        // pubSignals[2] matches challenge2's guess (41) so the guess check passes;
        // pubSignals[5] points at guesser1, which mismatches challenge2's guesser.
        uint256[6] memory proofForGuesser1 = _pubSig(COMMITMENT_42_123, 0, 41, 100, puzzleId, guesser);

        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidGuesserBinding.selector);
        game.respondToChallenge(puzzleId, c2, proofA, proofB, proofC, proofForGuesser1);

        // Sanity: c1 still resolvable normally.
        uint256[6] memory legitProof1 = _pubSig(COMMITMENT_42_123, 1, 42, 100, puzzleId, guesser);
        vm.prank(creator);
        game.respondToChallenge(puzzleId, c1, proofA, proofB, proofC, legitProof1);
    }

    /// @notice The most direct "this is not a mixer" assertion: even the privileged
    ///         caller (the puzzle creator) cannot redirect the prize to themselves
    ///         by manipulating pubSignals.
    function test_NotAMixer_CreatorCannotInjectSelfAsRecipient() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Creator tries to claim the prize by setting guesserAddr = creator.
        uint256[6] memory selfPay = _pubSig(COMMITMENT_42_123, 1, 42, 100, puzzleId, creator);

        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidGuesserBinding.selector);
        game.respondToChallenge(puzzleId, challengeId, proofA, proofB, proofC, selfPay);
    }

    /// @notice MIXER would: a "burn" recipient (0x0) plus a re-claim is a classic mixing
    ///         primitive. Closed off here: pubSignals[5] = 0 fails the binding check.
    function test_NotAMixer_ZeroAddressGuesserRejected() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        uint256[6] memory zeroPay = _pubSig(COMMITMENT_42_123, 1, 42, 100, puzzleId, address(0));

        vm.prank(creator);
        vm.expectRevert(IGuessGame.InvalidGuesserBinding.selector);
        game.respondToChallenge(puzzleId, challengeId, proofA, proofB, proofC, zeroPay);
    }

    // =========================================================================
    // C. Recipient is state-fixed, never user-supplied
    // =========================================================================

    /// @notice MIXER: withdrawal includes a recipient parameter; payee == caller-chosen.
    /// @notice HERE: respondToChallenge has NO recipient parameter. The prize lands at
    ///         `challenge.guesser` — unchangeable post-deposit.
    function test_NotAMixer_PrizePaidToChallengeGuesser_NotMsgSender() public {
        uint256 bounty = 0.0001 ether;
        uint256 stake = 0.01 ether;
        uint256 collateral = 0.2 ether - bounty;

        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, bounty, stake, 100);

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: stake}(puzzleId, 42);

        uint256 creatorBefore = creator.balance;
        uint256 guesserBefore = guesser.balance;

        // Creator submits the proof. msg.sender == creator. But the prize lands at challenge.guesser.
        uint256[6] memory legit = _pubSig(COMMITMENT_42_123, 1, 42, 100, puzzleId, guesser);
        vm.prank(creator);
        game.respondToChallenge(puzzleId, challengeId, proofA, proofB, proofC, legit);

        // Creator's external ETH balance is unchanged (collateral is credited to balances[creator],
        // not paid out). Guesser's external ETH balance increased by bounty + stake.
        assertEq(creator.balance, creatorBefore, "creator received nothing externally");
        assertEq(guesser.balance, guesserBefore + bounty + stake, "guesser got bounty + stake");
        assertEq(game.balances(creator), collateral, "collateral credited to creator's pull-balance");
    }

    /// @notice MIXER: anyone with a withdrawal proof + recipient address gets paid.
    /// @notice HERE: there is no recipient parameter on any path. claim/withdraw pay
    ///         msg.sender ONLY; an attacker without state cannot extract anything.
    function test_NotAMixer_NoRecipientParameter_ClaimAndWithdrawPayMsgSenderOnly() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);

        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 0.2 ether}(COMMITMENT_42_123, 0.0001 ether, 0.01 ether, 100);
        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        // Force a forfeit (creator never responds).
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, challengeId);

        // Attacker (no challenges) cannot claim from the forfeited puzzle.
        vm.prank(attacker);
        vm.expectRevert(IGuessGame.NothingToClaim.selector);
        game.claimFromForfeited(puzzleId);

        // Real guesser claims — funds go into balances[guesser].
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);
        assertGt(game.balances(guesser), 0, "guesser owed funds");
        assertEq(game.balances(attacker), 0, "attacker owed nothing");

        // Attacker tries withdraw — pays msg.sender, attacker has zero balance.
        vm.prank(attacker);
        vm.expectRevert(IGuessGame.NothingToWithdraw.selector);
        game.withdraw();

        // Real guesser withdraws — pays msg.sender (guesser).
        uint256 guesserBefore = guesser.balance;
        vm.prank(guesser);
        game.withdraw();
        assertGt(guesser.balance, guesserBefore, "guesser was paid by withdraw");
    }

    // =========================================================================
    // D. No fungible pool (variable denominations)
    // =========================================================================

    /// @notice MIXER: a fixed denomination defines an anonymity set.
    /// @notice HERE: each puzzle is its own accounting unit with caller-chosen
    ///         (bounty, stakeRequired). No pool-level fungibility; no anonymity set.
    function test_NotAMixer_VariableDenominations_PerPuzzleAccounting() public {
        // Three distinct (bounty, stakeRequired) shapes — none rounded to a fixed value.
        vm.prank(creator);
        uint256 p1 = game.createPuzzle{value: 0.0001 ether}(COMMITMENT_42_123, 0.0001 ether, 0.00001 ether, 100);
        vm.prank(creator);
        uint256 p2 = game.createPuzzle{value: 0.001 ether}(COMMITMENT_42_123, 0.001 ether, 0.0005 ether, 100);
        vm.prank(creator);
        uint256 p3 = game.createPuzzle{value: 0.05 ether}(COMMITMENT_42_123, 0.05 ether, 0.02 ether, 100);

        IGuessGame.Puzzle memory P1 = game.getPuzzle(p1);
        IGuessGame.Puzzle memory P2 = game.getPuzzle(p2);
        IGuessGame.Puzzle memory P3 = game.getPuzzle(p3);

        // All three (bounty, stake) shapes are distinct — no rounding to a common denom.
        assertTrue(P1.bounty != P2.bounty && P2.bounty != P3.bounty && P1.bounty != P3.bounty);
        assertTrue(
            P1.stakeRequired != P2.stakeRequired && P2.stakeRequired != P3.stakeRequired
                && P1.stakeRequired != P3.stakeRequired
        );

        // Per-puzzle stake gating: a stake that satisfies puzzle 1's MIN_STAKE-ish floor
        // is INSUFFICIENT for puzzle 3 (which requires 0.02 ether).
        vm.prank(guesser);
        vm.expectRevert(IGuessGame.InsufficientStake.selector);
        game.submitGuess{value: 0.0001 ether}(p3, 42);

        // Conversely, paying puzzle 3's stake into puzzle 1 succeeds and stakes the FULL
        // amount (not capped to puzzle 1's MIN). Confirms each puzzle accounts independently.
        vm.prank(guesser);
        uint256 c1 = game.submitGuess{value: 0.02 ether}(p1, 42);
        IGuessGame.Challenge memory ch = game.getChallenge(p1, c1);
        assertEq(ch.stake, 0.02 ether, "stake recorded at full caller value, not rounded");
    }

    // =========================================================================
    // E. Per-puzzle ETH conservation (no anonymity-set bleed)
    // =========================================================================

    /// @notice MIXER: a residual pool persists by design (the anonymity set).
    /// @notice HERE: every wei has a named recipient. After a solved-path full cycle
    ///         (create → guess → respond → withdraw), the contract balance is exactly 0.
    function test_NotAMixer_ETHConservation_SolvedPath() public {
        uint256 bounty = 0.0001 ether;
        uint256 stake = 0.01 ether;
        uint256 collateral = 0.1999 ether;
        uint256 deposit = bounty + collateral;

        assertEq(address(game).balance, 0, "fresh game starts at 0");

        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: deposit}(COMMITMENT_42_123, bounty, stake, 100);
        assertEq(address(game).balance, deposit, "after create");

        vm.prank(guesser);
        uint256 challengeId = game.submitGuess{value: stake}(puzzleId, 42);
        assertEq(address(game).balance, deposit + stake, "after submit");

        uint256[6] memory legit = _pubSig(COMMITMENT_42_123, 1, 42, 100, puzzleId, guesser);
        vm.prank(creator);
        game.respondToChallenge(puzzleId, challengeId, proofA, proofB, proofC, legit);
        // Bounty + stake paid out to guesser; only the creator's collateral remains as a credit.
        assertEq(address(game).balance, collateral, "after respond");
        assertEq(game.balances(creator), collateral, "creator's pull-balance == collateral");

        vm.prank(creator);
        game.withdraw();
        assertEq(address(game).balance, 0, "fully drained after creator's withdraw - no residual pool");
    }

    /// @notice Same conservation property along the forfeit path: every wei has a
    ///         named recipient (guessers' stakes + bounty share) plus the labeled
    ///         treasury slash. No mixer-shaped residual.
    function test_NotAMixer_ETHConservation_ForfeitPath() public {
        uint256 bounty = 0.0001 ether;
        uint256 stake = 0.01 ether;
        uint256 collateral = 0.2 ether - bounty;
        uint256 deposit = bounty + collateral;

        address g3 = makeAddr("guesser3");
        vm.deal(g3, 100 ether);

        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: deposit}(COMMITMENT_42_123, bounty, stake, 100);

        vm.prank(guesser);
        game.submitGuess{value: stake}(puzzleId, 1);
        vm.prank(guesser2);
        game.submitGuess{value: stake}(puzzleId, 2);
        vm.prank(g3);
        game.submitGuess{value: stake}(puzzleId, 3);

        uint256 totalIn = deposit + 3 * stake;
        assertEq(address(game).balance, totalIn, "all deposits accounted for");

        // Force forfeit; collateral lands at treasury (an EOA in this test setup).
        uint256 treasuryBefore = treasury.balance;
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);
        assertEq(treasury.balance, treasuryBefore + collateral, "collateral slashed to treasury");
        assertEq(address(game).balance, totalIn - collateral, "contract holds bounty + stakes");

        // Each guesser claims, then withdraws. Stakes go back; bounty is split via
        // the cumulative-divisor algorithm (last claimer absorbs rounding).
        vm.prank(guesser);
        game.claimFromForfeited(puzzleId);
        vm.prank(guesser2);
        game.claimFromForfeited(puzzleId);
        vm.prank(g3);
        game.claimFromForfeited(puzzleId);

        vm.prank(guesser);
        game.withdraw();
        vm.prank(guesser2);
        game.withdraw();
        vm.prank(g3);
        game.withdraw();

        // Every wei has been routed somewhere: 3 stakes back to guessers, bounty split
        // among guessers, collateral to treasury. Contract is exactly empty.
        assertEq(address(game).balance, 0, "fully drained - no residual mixer pool");
    }
}
