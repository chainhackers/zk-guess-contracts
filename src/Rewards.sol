// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title Rewards
/// @notice Merkle-distributed rewards pool funded by GuessGame forfeit collateral and
///         labeled donations via fundRewards(purpose).
/// @dev Non-upgradeable. Owner publishes monotonically-increasing epoch roots; users claim
///      by proof. Eligibility rules live off-chain in the indexer. Bare ETH transfers revert
///      (no `receive`) so every inbound transfer carries a scanner-readable purpose.
/// @custom:repository https://github.com/chainhackers/zk-guess-contracts
/// @custom:homepage https://zk-guess.chainhackers.xyz
/// @custom:security-contact security@chainhackers.xyz
contract Rewards is Ownable {
    /// @notice Merkle root for each epoch
    mapping(uint256 => bytes32) public roots;

    /// @notice Whether a recipient has already claimed for a given epoch
    mapping(uint256 => mapping(address => bool)) public claimed;

    /// @notice Monotonic epoch counter; incremented by publishRoot
    uint256 public currentEpoch;

    event RootPublished(uint256 indexed epoch, bytes32 root);
    event Claimed(uint256 indexed epoch, address indexed user, uint256 amount);

    /// @notice Emitted when ETH enters the pool through the labeled fundRewards path.
    /// @dev `purpose` carries the on-chain semantic context that distinguishes forfeit
    ///      collateral routing, stale-bounty sweeps, settlement dust, and donations.
    event RewardsFunded(address indexed funder, uint256 amount, string purpose);

    error InvalidRoot();
    error EpochNotPublished();
    error InvalidProof();
    error AlreadyClaimed();
    error TransferFailed();

    /// @notice Reverts a fundRewards call with zero msg.value — empty contributions don't
    ///         carry useful information and would clutter the event channel.
    error EmptyContribution();

    /// @notice Reverts a fundRewards call with an empty purpose string — every contribution
    ///         must label its on-chain semantic context.
    error EmptyPurpose();

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Add ETH to the rewards pool with a labeled purpose.
    /// @param purpose Free-form context tag (e.g. "forfeit-collateral-routing", "donation").
    ///                Must be non-empty.
    /// @dev Replaces the bare `receive()` so every inbound transfer carries scanner-readable
    ///      intent (anti-mixer hardening). Anyone can call; no permission gate.
    function fundRewards(string calldata purpose) external payable {
        if (msg.value == 0) revert EmptyContribution();
        if (bytes(purpose).length == 0) revert EmptyPurpose();
        emit RewardsFunded(msg.sender, msg.value, purpose);
    }

    /// @notice Publish a new epoch merkle root
    /// @param root Merkle root over (address, amount) leaves using OpenZeppelin MerkleProof convention
    /// @return epoch The epoch number assigned to this root (starts at 1)
    function publishRoot(bytes32 root) external onlyOwner returns (uint256 epoch) {
        if (root == bytes32(0)) revert InvalidRoot();
        epoch = ++currentEpoch;
        roots[epoch] = root;
        emit RootPublished(epoch, root);
    }

    /// @notice Claim an epoch reward by providing the merkle proof for (msg.sender, amount)
    /// @param epoch Epoch number to claim
    /// @param amount Amount encoded in the merkle leaf
    /// @param proof Sibling hashes from leaf to root
    /// @dev Leaf format: keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))))
    function claim(uint256 epoch, uint256 amount, bytes32[] calldata proof) external {
        if (claimed[epoch][msg.sender]) revert AlreadyClaimed();
        bytes32 root = roots[epoch];
        if (root == bytes32(0)) revert EpochNotPublished();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        if (!MerkleProof.verify(proof, root, leaf)) revert InvalidProof();

        claimed[epoch][msg.sender] = true;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Claimed(epoch, msg.sender, amount);
    }
}
