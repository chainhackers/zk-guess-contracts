// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ISettleable
/// @notice Interface for contracts that can permanently settle all funds and disable themselves
interface ISettleable {
    /// @notice Emitted when a non-final settlement batch is distributed via settle()
    event SettlementBatch(address indexed settler, uint256 totalDistributed, uint256 recipientCount);

    /// @notice Emitted when the contract is permanently settled via settleAll()
    /// @dev `reason` is emitted (not stored) — persisted in event logs for on-chain audit
    event Settled(address indexed settler, uint256 totalDistributed, uint256 recipientCount, string reason);

    /// @notice Thrown when calling a function after the contract has been settled
    error ContractSettled();

    /// @notice Thrown when settleAll is called with empty recipient list
    error EmptySettlement();

    /// @notice Thrown when contract balance is not zero after settlement
    error BalanceMismatch();

    /// @notice Thrown when ETH transfer to a recipient fails
    error SettleTransferFailed();

    /// @notice Whether the contract has been permanently settled
    function settled() external view returns (bool);

    /// @notice Settle all funds to recipients and permanently disable the contract
    /// @param recipients Addresses to receive their computed funds
    /// @param reason Human-readable explanation emitted in the Settled event for on-chain audit
    /// @dev Amounts are computed on-chain via _computeOwed(). Contract balance must be zero after.
    function settleAll(address[] calldata recipients, string calldata reason) external;
}
