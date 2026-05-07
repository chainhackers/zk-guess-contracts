// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ISettleable
/// @notice Interface for contracts that can permanently settle all funds and disable themselves
/// @dev Settlement walks an on-chain auto-populated queue at a monotonic cursor. The owner
///      cannot pick or skip recipients (anti-mixer hardening).
interface ISettleable {
    /// @notice Emitted per-batch by settleNext
    /// @param cursorStart Queue index at the start of the batch
    /// @param cursorEnd Queue index after advancing (exclusive)
    /// @param totalDistributed Total ETH distributed in this batch (excludes already-paid)
    /// @param reason Human-readable explanation persisted in event logs
    event SettledBatch(uint256 cursorStart, uint256 cursorEnd, uint256 totalDistributed, string reason);

    /// @notice Emitted per-recipient on payout (one per non-zero settleNext payment)
    event SettledPaid(address indexed recipient, uint256 amount);

    /// @notice Emitted once when the contract is permanently settled via settleAll()
    /// @dev `reason` is emitted (not stored) — persisted in event logs for on-chain audit
    event Settled(address indexed settler, uint256 dustSwept, uint256 finalCursor, string reason);

    /// @notice Thrown when calling a function after the contract has been settled
    error ContractSettled();

    /// @notice Thrown when contract balance is not zero after settlement
    error BalanceMismatch();

    /// @notice Thrown when ETH transfer to a recipient fails
    error SettleTransferFailed();

    /// @notice Thrown when settleNext or settleAll is called but the precondition (paused +
    ///         every puzzle terminal + claim windows elapsed) is not met
    error CannotSettle();

    /// @notice Thrown when settleNext is called past the end of the queue
    error CursorBeyondQueue();

    /// @notice Thrown when settleAll is called before the cursor reaches the end of the queue
    error CursorBehindQueue();

    /// @notice Whether the contract has been permanently settled
    function settled() external view returns (bool);

    /// @notice Pay the next `n` queued recipients (auto-advancing the cursor)
    function settleNext(uint256 n, string calldata reason) external;

    /// @notice Finalize settlement: sweep dust to treasury, mark settled, renounce ownership
    function settleAll(string calldata reason) external;
}
