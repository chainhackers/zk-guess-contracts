// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import "../src/Rewards.sol";
import "../src/generated/GuessVerifier.sol";

contract RewardsIntegrationTest is Test {
    Groth16Verifier public verifier;
    GuessGame public game;
    Rewards public rewards;

    address owner;
    address creator;
    address guesser;
    address alice;
    address bob;

    bytes32 commitment;

    function setUp() public {
        owner = makeAddr("owner");
        creator = makeAddr("creator");
        guesser = makeAddr("guesser");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.deal(creator, 10 ether);
        vm.deal(guesser, 10 ether);

        commitment = keccak256(abi.encodePacked(uint256(42), uint256(123)));

        verifier = new Groth16Verifier();

        // Deploy Rewards first, use its address as GuessGame's treasury
        rewards = new Rewards(owner);

        GuessGame impl = new GuessGame();
        bytes memory initData = abi.encodeCall(GuessGame.initialize, (address(verifier), address(rewards), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        game = GuessGame(address(proxy));
    }

    function _leaf(address user, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(user, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function test_forfeitCollateralFundsRewardsPool() public {
        // Create puzzle with 0.5 ether collateral (msg.value - bounty)
        uint256 bounty = 0.0001 ether;
        uint256 collateral = 0.5 ether;

        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: bounty + collateral}(commitment, bounty, 0.01 ether, 100);

        // Guesser submits — forfeit needs a pending challenge
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);

        uint256 rewardsBefore = address(rewards).balance;
        assertEq(rewardsBefore, 0);

        // Warp past response timeout and forfeit
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);

        // Rewards pool should now hold the slashed collateral
        assertEq(address(rewards).balance, rewardsBefore + collateral);
    }

    function test_threeRecipientDropFromForfeitedPool() public {
        // Forfeit a puzzle to fund the rewards pool
        uint256 bounty = 0.0001 ether;
        uint256 collateral = 0.3 ether;

        vm.prank(creator);
        uint256 puzzleId = game.createPuzzle{value: bounty + collateral}(commitment, bounty, 0.01 ether, 100);
        vm.prank(guesser);
        game.submitGuess{value: 0.01 ether}(puzzleId, 42);
        vm.warp(block.timestamp + game.RESPONSE_TIMEOUT() + 1);
        game.forfeitPuzzle(puzzleId, 0);

        assertEq(address(rewards).balance, collateral);

        // Build a 3-recipient merkle tree: alice=0.1, bob=0.15, (creator reserved)=0.05
        uint256 aliceAmt = 0.1 ether;
        uint256 bobAmt = 0.15 ether;
        uint256 carolAmt = 0.05 ether;
        address carol = makeAddr("carol");

        bytes32 leafA = _leaf(alice, aliceAmt);
        bytes32 leafB = _leaf(bob, bobAmt);
        bytes32 leafC = _leaf(carol, carolAmt);

        // 3-leaf tree: pair (A, B) at depth 1, then pair with C at depth 0
        bytes32 hashAB = _hashPair(leafA, leafB);
        bytes32 root = _hashPair(hashAB, leafC);

        vm.prank(owner);
        rewards.publishRoot(root);

        // Alice proof: [B, C]
        bytes32[] memory proofA = new bytes32[](2);
        proofA[0] = leafB;
        proofA[1] = leafC;
        vm.prank(alice);
        rewards.claim(1, aliceAmt, proofA);
        assertEq(alice.balance, aliceAmt);

        // Bob proof: [A, C]
        bytes32[] memory proofB = new bytes32[](2);
        proofB[0] = leafA;
        proofB[1] = leafC;
        vm.prank(bob);
        rewards.claim(1, bobAmt, proofB);
        assertEq(bob.balance, bobAmt);

        // Carol proof: [AB]
        bytes32[] memory proofC = new bytes32[](1);
        proofC[0] = hashAB;
        vm.prank(carol);
        rewards.claim(1, carolAmt, proofC);
        assertEq(carol.balance, carolAmt);

        // Pool decreased by total claimed
        assertEq(address(rewards).balance, collateral - aliceAmt - bobAmt - carolAmt);
    }
}
