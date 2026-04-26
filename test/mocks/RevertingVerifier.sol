// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Always-reverting verifier mock. Used to prove the contract rejects mismatched
/// pubSignals BEFORE paying the pairing-check cost — if `verifyProof` ever runs, this
/// reverts with `VerifierUnreachable`, so any test asserting a binding-check selector
/// instead of `VerifierUnreachable` is also asserting fail-fast ordering.
contract RevertingVerifier {
    error VerifierUnreachable();

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[6] calldata)
        external
        pure
        returns (bool)
    {
        revert VerifierUnreachable();
    }
}
