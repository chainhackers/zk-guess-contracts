// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/ISettleable.sol";

/// @title Settleable
/// @notice Abstract contract for permanently settling all funds and disabling the contract
/// @dev Stateless — inheritors provide storage via _isSettled/_setSettled, _isPaid/_markPaid,
///      and _computeOwed. Settlement renounces ownership permanently. Per-address payment
///      tracking makes partial batches idempotent (safe to retry / overlap).
abstract contract Settleable is ISettleable, OwnableUpgradeable {
    /// @notice Distribute funds to a batch of recipients without finalizing
    /// @dev Callable multiple times to split settlement across txs (for gas limits).
    ///      Does not mark settled or renounce ownership. Use settleAll for the final batch.
    ///      Recipients already paid are silently skipped — overlap/retry is safe.
    function settle(address[] calldata recipients) external onlyOwner {
        if (_isSettled()) revert ContractSettled();
        if (recipients.length == 0) revert EmptySettlement();

        uint256 totalDistributed;
        for (uint256 i; i < recipients.length; i++) {
            address r = recipients[i];
            if (_isPaid(r)) continue;
            uint256 owed = _computeOwed(r);
            _markPaid(r);
            if (owed > 0) {
                totalDistributed += owed;
                (bool success,) = r.call{value: owed}("");
                if (!success) revert SettleTransferFailed();
            }
        }

        emit SettlementBatch(msg.sender, totalDistributed, recipients.length);
    }

    /// @inheritdoc ISettleable
    function settleAll(address[] calldata recipients, string calldata reason) external onlyOwner {
        if (_isSettled()) revert ContractSettled();
        if (recipients.length == 0) revert EmptySettlement();

        _setSettled();

        uint256 totalDistributed;
        for (uint256 i; i < recipients.length; i++) {
            address r = recipients[i];
            if (_isPaid(r)) continue;
            uint256 owed = _computeOwed(r);
            _markPaid(r);
            if (owed > 0) {
                totalDistributed += owed;
                (bool success,) = r.call{value: owed}("");
                if (!success) revert SettleTransferFailed();
            }
        }

        // Sweep integer division rounding dust (max 10000 wei — enough for realistic
        // forfeited-puzzle rounding, small enough to catch misconfigured settlements)
        uint256 dust = address(this).balance;
        if (dust > 0 && dust <= 10000) {
            totalDistributed += dust;
            (bool ok,) = recipients[recipients.length - 1].call{value: dust}("");
            if (!ok) revert SettleTransferFailed();
        }

        emit Settled(msg.sender, totalDistributed, recipients.length, reason);
        if (address(this).balance != 0) revert BalanceMismatch();
        _transferOwnership(address(0));
    }

    /// @dev Whether the contract has been settled. Implemented by inheritor (storage lives there).
    function _isSettled() internal view virtual returns (bool);

    /// @dev Mark the contract as settled. Implemented by inheritor.
    function _setSettled() internal virtual;

    /// @dev Whether addr has already been paid during settlement. Implemented by inheritor.
    function _isPaid(address addr) internal view virtual returns (bool);

    /// @dev Mark addr as paid during settlement. Implemented by inheritor.
    function _markPaid(address addr) internal virtual;

    /// @dev Compute total ETH owed to an address. Implemented by inheritor.
    function _computeOwed(address addr) internal view virtual returns (uint256 owed);
}
