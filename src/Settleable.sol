// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/ISettleable.sol";

/// @title Settleable
/// @notice Abstract contract for permanently settling all funds and disabling the contract
/// @dev Settlement walks an inheritor-managed deterministic queue (`_potentiallyOwed`) at the
///      cursor position the inheritor exposes. Owner cannot single out or omit specific
///      addresses — the queue is auto-populated by user interactions in the inheritor.
///      Inheritors implement: queue accessors, settled flag, paid flag, computed-owed,
///      a `_canSettle()` precondition (e.g. paused + every puzzle terminal + claim windows
///      elapsed), and `_routeDustToTreasury` for the final-settlement rounding sweep.
abstract contract Settleable is ISettleable, OwnableUpgradeable {
    /// @notice Upper bound on the residual contract balance that settleAll is allowed to
    ///         sweep to the treasury as "dust". Sized to absorb realistic integer-division
    ///         rounding (a few thousand wei across all forfeited puzzles); anything larger
    ///         indicates an accounting bug or a stale precondition and aborts the finalize.
    uint256 public constant MAX_DUST = 10000;

    /// @notice Pay the next `n` addresses in the settlement queue, in order
    /// @param n Maximum number of queue entries to advance through
    /// @param reason Human-readable explanation emitted on the SettledBatch event
    /// @dev Idempotent on already-paid entries (skips them). Skips entries with zero owed
    ///      so unrelated zero-balance addresses don't bloat batch logs.
    function settleNext(uint256 n, string calldata reason) external onlyOwner {
        if (_isSettled()) revert ContractSettled();
        if (!_canSettle()) revert CannotSettle();

        uint256 cursor = _readSettleCursor();
        uint256 length = _potentiallyOwedLength();
        if (cursor >= length) revert CursorBeyondQueue();

        // Clamp before adding so an oversized n (e.g. type(uint256).max) doesn't overflow.
        uint256 remaining = length - cursor;
        uint256 end = n >= remaining ? length : cursor + n;

        uint256 totalDistributed;
        for (uint256 i = cursor; i < end; i++) {
            address r = _potentiallyOwedAt(i);
            if (_isPaid(r)) continue;
            uint256 owed = _computeOwed(r);
            _markPaid(r);
            if (owed > 0) {
                totalDistributed += owed;
                emit SettledPaid(r, owed);
                (bool success,) = r.call{value: owed}("");
                if (!success) revert SettleTransferFailed();
            }
        }

        _writeSettleCursor(end);
        emit SettledBatch(cursor, end, totalDistributed, reason);
    }

    /// @notice Finalize settlement: sweep rounding dust to treasury, mark settled, renounce ownership
    /// @param reason Human-readable explanation emitted on the Settled event
    /// @dev Requires the cursor to have reached the end of the queue. Any residual contract
    ///      balance is routed through the inheritor's `_routeDustToTreasury` (a labeled
    ///      `Rewards.fundRewards` call in the GuessGame integration) so even the dust carries
    ///      a scanner-readable purpose.
    function settleAll(string calldata reason) external onlyOwner {
        if (_isSettled()) revert ContractSettled();
        if (!_canSettle()) revert CannotSettle();
        uint256 cursor = _readSettleCursor();
        if (cursor < _potentiallyOwedLength()) revert CursorBehindQueue();

        _setSettled();

        uint256 dust = address(this).balance;
        // Cap the sweep at MAX_DUST. With _canSettle()'s frozen-accounting precondition,
        // the post-settleNext balance should only contain integer-division rounding from
        // claimFromForfeited's cumulative-divisor algorithm — at most a few thousand wei.
        // A larger remainder signals an accounting bug, so revert rather than silently
        // routing significant user funds to the treasury.
        if (dust > MAX_DUST) revert ExcessiveDust(dust);
        if (dust > 0) {
            _routeDustToTreasury(dust, "final-settlement-dust");
        }

        if (address(this).balance != 0) revert BalanceMismatch();

        emit Settled(msg.sender, dust, cursor, reason);
        _transferOwnership(address(0));
    }

    // ============ Inheritor hooks ============

    /// @dev Whether the contract has been settled. Implemented by inheritor.
    function _isSettled() internal view virtual returns (bool);

    /// @dev Mark the contract as settled. Implemented by inheritor.
    function _setSettled() internal virtual;

    /// @dev Whether addr has already been paid during settlement. Implemented by inheritor.
    function _isPaid(address addr) internal view virtual returns (bool);

    /// @dev Mark addr as paid during settlement. Implemented by inheritor.
    function _markPaid(address addr) internal virtual;

    /// @dev Compute total ETH owed to an address. Implemented by inheritor.
    function _computeOwed(address addr) internal view virtual returns (uint256 owed);

    /// @dev Length of the inheritor's deterministic settlement queue.
    function _potentiallyOwedLength() internal view virtual returns (uint256);

    /// @dev Address at queue position `i` in the inheritor's queue.
    function _potentiallyOwedAt(uint256 i) internal view virtual returns (address);

    /// @dev Read the inheritor's settlement cursor.
    function _readSettleCursor() internal view virtual returns (uint256);

    /// @dev Write the inheritor's settlement cursor (after settleNext advances it).
    function _writeSettleCursor(uint256 v) internal virtual;

    /// @dev Inheritor-defined precondition (e.g. paused + every terminal puzzle + claim window).
    function _canSettle() internal view virtual returns (bool);

    /// @dev Route the final dust sweep through the inheritor's labeled treasury path.
    function _routeDustToTreasury(uint256 amount, string memory reason) internal virtual;
}
