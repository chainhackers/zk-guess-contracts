// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import "../src/Rewards.sol";
import "../src/interfaces/IGuessGame.sol";
import {AlwaysAcceptVerifier} from "./mocks/AlwaysAcceptVerifier.sol";

/// @dev Test harness exposing the internal `_computeOwed` so defense-in-depth assertions can
///      run independently of `canSettle`'s precondition. Production callers (settleNext,
///      settleAll) gate on `_canSettle()`; this harness lets us prove the inner accounting
///      is safe even if that gate were bypassed.
contract ExposedGuessGame is GuessGame {
    function exposed_computeOwed(address addr) external view returns (uint256) {
        return _computeOwed(addr);
    }
}

/// @notice Lock in defense-in-depth: `_computeOwed` must NOT credit creator funds for
///         non-terminal puzzles, even when called outside the canSettle gate. The active
///         branch was previously reachable in principle and only safe because canSettle
///         blocks settleNext/settleAll while any puzzle is active.
contract ComputeOwedTest is Test {
    ExposedGuessGame public game;
    AlwaysAcceptVerifier public verifier;
    Rewards public treasury;

    address owner;
    address creator;
    address guesser;

    bytes32 commitment;

    function setUp() public {
        owner = makeAddr("owner");
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");

        vm.deal(creator, 10 ether);
        vm.deal(guesser, 10 ether);

        commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));

        verifier = new AlwaysAcceptVerifier();
        treasury = new Rewards(owner);

        ExposedGuessGame impl = new ExposedGuessGame();
        bytes memory initData = abi.encodeCall(GuessGame.initialize, (address(verifier), address(treasury), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        game = ExposedGuessGame(address(proxy));
    }

    /// @notice An active puzzle's bounty + collateral must NOT show up as "owed" to the
    ///         creator — those funds belong to active guessers (potential winners) and to
    ///         the treasury (slashed collateral on forfeit). canSettle already blocks this
    ///         path, but the inner accounting must be safe even without that gate.
    function test_computeOwed_activePuzzleCreator_returnsZero() public {
        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: 1 ether}(commitment, 0.5 ether, 0.01 ether, 100);

        // Submit a guess so the puzzle is fully alive (bounty 0.5 + collateral 0.5 + stake 0.01
        // are all locked in the contract). At this point the puzzle is non-terminal.
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 1);

        IGuessGame.Puzzle memory p = game.getPuzzle(puzzleId);
        assertEq(p.solved, false);
        assertEq(p.cancelled, false);
        assertEq(p.forfeited, false);

        // Creator has no internal balance and no terminal-puzzle credits — the only thing
        // that could push owed > 0 is a stray active-puzzle branch, which must not exist.
        assertEq(game.balances(creator), 0);
        assertEq(game.exposed_computeOwed(creator), 0, "active puzzle creator must not be owed bounty/collateral");
    }
}
