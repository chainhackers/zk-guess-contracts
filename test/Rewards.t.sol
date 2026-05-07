// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../src/Rewards.sol";

contract RewardsTest is Test {
    Rewards public rewards;

    address owner;
    address alice;
    address bob;
    address carol;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        rewards = new Rewards(owner);
        vm.deal(address(rewards), 10 ether);
    }

    function _leaf(address user, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(user, amount))));
    }

    // OZ MerkleProof hashes children with sorting — replicate it for test tree building
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    // ============ publishRoot ============

    function test_publishRoot_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rewards.publishRoot(bytes32(uint256(1)));
    }

    function test_publishRoot_monotonicEpoch() public {
        assertEq(rewards.currentEpoch(), 0);

        vm.prank(owner);
        uint256 e1 = rewards.publishRoot(bytes32(uint256(1)));
        assertEq(e1, 1);
        assertEq(rewards.currentEpoch(), 1);

        vm.prank(owner);
        uint256 e2 = rewards.publishRoot(bytes32(uint256(2)));
        assertEq(e2, 2);
        assertEq(rewards.currentEpoch(), 2);

        assertEq(rewards.roots(1), bytes32(uint256(1)));
        assertEq(rewards.roots(2), bytes32(uint256(2)));
    }

    function test_publishRoot_rejectsZeroRoot() public {
        vm.prank(owner);
        vm.expectRevert(Rewards.InvalidRoot.selector);
        rewards.publishRoot(bytes32(0));
    }

    function test_publishRoot_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Rewards.RootPublished(1, bytes32(uint256(0xdead)));

        vm.prank(owner);
        rewards.publishRoot(bytes32(uint256(0xdead)));
    }

    // ============ claim ============

    function test_claim_singleLeaf() public {
        // Tree with 1 leaf: root == leaf
        uint256 amount = 0.1 ether;
        bytes32 leaf = _leaf(alice, amount);

        vm.prank(owner);
        rewards.publishRoot(leaf);

        uint256 aliceBefore = alice.balance;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        rewards.claim(1, amount, proof);

        assertEq(alice.balance, aliceBefore + amount);
        assertEq(rewards.claimed(1, alice), true);
    }

    function test_claim_twoLeafTree() public {
        // Tree with 2 leaves — alice and bob
        uint256 aliceAmount = 0.1 ether;
        uint256 bobAmount = 0.2 ether;
        bytes32 leafA = _leaf(alice, aliceAmount);
        bytes32 leafB = _leaf(bob, bobAmount);
        bytes32 root = _hashPair(leafA, leafB);

        vm.prank(owner);
        rewards.publishRoot(root);

        // Alice claims
        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        vm.prank(alice);
        rewards.claim(1, aliceAmount, proofA);
        assertEq(alice.balance, aliceAmount);

        // Bob claims
        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = leafA;
        vm.prank(bob);
        rewards.claim(1, bobAmount, proofB);
        assertEq(bob.balance, bobAmount);
    }

    function test_claim_emitsEvent() public {
        bytes32 leaf = _leaf(alice, 0.1 ether);
        vm.prank(owner);
        rewards.publishRoot(leaf);

        vm.expectEmit(true, true, false, true);
        emit Rewards.Claimed(1, alice, 0.1 ether);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        rewards.claim(1, 0.1 ether, proof);
    }

    function test_claim_revertsOnInvalidProof() public {
        bytes32 leaf = _leaf(alice, 0.1 ether);
        vm.prank(owner);
        rewards.publishRoot(leaf);

        // Wrong amount
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(Rewards.InvalidProof.selector);
        rewards.claim(1, 0.2 ether, proof);
    }

    function test_claim_revertsOnWrongUser() public {
        // Leaf for alice; bob tries to claim
        bytes32 leaf = _leaf(alice, 0.1 ether);
        vm.prank(owner);
        rewards.publishRoot(leaf);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(bob);
        vm.expectRevert(Rewards.InvalidProof.selector);
        rewards.claim(1, 0.1 ether, proof);
    }

    function test_claim_revertsOnDoubleClaim() public {
        bytes32 leaf = _leaf(alice, 0.1 ether);
        vm.prank(owner);
        rewards.publishRoot(leaf);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        rewards.claim(1, 0.1 ether, proof);

        vm.prank(alice);
        vm.expectRevert(Rewards.AlreadyClaimed.selector);
        rewards.claim(1, 0.1 ether, proof);
    }

    function test_claim_revertsOnUnpublishedEpoch() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(Rewards.EpochNotPublished.selector);
        rewards.claim(99, 0.1 ether, proof);
    }

    function test_claim_revertsOnInsufficientBalance() public {
        // Drain pool, then publish root for a big claim
        vm.deal(address(rewards), 0.05 ether);

        bytes32 leaf = _leaf(alice, 0.1 ether);
        vm.prank(owner);
        rewards.publishRoot(leaf);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(Rewards.TransferFailed.selector);
        rewards.claim(1, 0.1 ether, proof);
    }

    function test_claim_sameUserAcrossEpochs() public {
        // Claim twice for same user in different epochs — both succeed
        bytes32 leaf1 = _leaf(alice, 0.1 ether);
        bytes32 leaf2 = _leaf(alice, 0.05 ether);

        vm.prank(owner);
        rewards.publishRoot(leaf1);
        vm.prank(owner);
        rewards.publishRoot(leaf2);

        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        rewards.claim(1, 0.1 ether, proof);
        vm.prank(alice);
        rewards.claim(2, 0.05 ether, proof);

        assertEq(alice.balance, 0.15 ether);
    }

    // ============ fundRewards (gates the funding path; replaces bare receive) ============

    function test_bareETH_reverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(rewards).call{value: 0.5 ether}("");
        assertFalse(ok);
    }

    function test_fundRewards_acceptsETHWithLabel() public {
        uint256 balanceBefore = address(rewards).balance;
        vm.deal(alice, 1 ether);
        vm.expectEmit(true, false, false, true, address(rewards));
        emit Rewards.RewardsFunded(alice, 0.5 ether, "donation");
        vm.prank(alice);
        rewards.fundRewards{value: 0.5 ether}("donation");
        assertEq(address(rewards).balance, balanceBefore + 0.5 ether);
    }

    function test_fundRewards_revertsOnZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(Rewards.EmptyContribution.selector);
        rewards.fundRewards("donation");
    }

    function test_fundRewards_revertsOnEmptyPurpose() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Rewards.EmptyPurpose.selector);
        rewards.fundRewards{value: 0.1 ether}("");
    }

    function test_fundRewards_acceptsFromAnySender() public {
        uint256 balanceBefore = address(rewards).balance;
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        rewards.fundRewards{value: 0.2 ether}("contributor-bob");
        assertEq(address(rewards).balance, balanceBefore + 0.2 ether);
    }

    // ============ ownership ============

    function test_transferOwnership_works() public {
        vm.prank(owner);
        rewards.transferOwnership(alice);
        assertEq(rewards.owner(), alice);

        // New owner can publish
        vm.prank(alice);
        rewards.publishRoot(bytes32(uint256(1)));
    }

    function test_renounceOwnership_works() public {
        vm.prank(owner);
        rewards.renounceOwnership();
        assertEq(rewards.owner(), address(0));

        // No one can publish after renounce
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        rewards.publishRoot(bytes32(uint256(1)));
    }
}
