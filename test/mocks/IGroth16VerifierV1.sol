// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Snapshot of the v1 verifier interface (4 public signals). Time-capsule mocks
/// (OldGuessGame, CurrentGuessGame) compile against this so they don't depend on the live
/// `IGroth16Verifier` (now [6]).
interface IGroth16VerifierV1 {
    function verifyProof(
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[4] calldata _pubSignals
    ) external view returns (bool);
}
