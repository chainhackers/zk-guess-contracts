// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title Rewards
/// @notice Merkle-distributed rewards pool funded by GuessGame forfeit collateral
/// @dev Non-upgradeable. Receives ETH from any source. Owner publishes monotonically-increasing
///      epoch roots; users claim by proof. Eligibility rules live off-chain in the indexer.
/// @custom:repository https://github.com/chainhackers/zk-guess-contracts
contract Rewards is Ownable {
    /// @notice Merkle root for each epoch
    mapping(uint256 => bytes32) public roots;

    /// @notice Whether a recipient has already claimed for a given epoch
    mapping(uint256 => mapping(address => bool)) public claimed;

    /// @notice Monotonic epoch counter; incremented by publishRoot
    uint256 public currentEpoch;

    event RootPublished(uint256 indexed epoch, bytes32 root);
    event Claimed(uint256 indexed epoch, address indexed user, uint256 amount);

    error InvalidRoot();
    error EpochNotPublished();
    error InvalidProof();
    error AlreadyClaimed();
    error TransferFailed();

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Accept ETH from any sender (forfeit collateral, donations, etc.)
    receive() external payable {}

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
