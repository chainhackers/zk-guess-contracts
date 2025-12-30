// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IGroth16Verifier
 * @notice Interface for Groth16 zero-knowledge proof verifiers
 * @dev This interface allows for composition-based integration of ZK verifiers,
 *      enabling free off-chain verification and better separation of concerns
 */
interface IGroth16Verifier {
    /**
     * @notice Verifies a Groth16 proof
     * @param _pA Point A of the proof
     * @param _pB Point B of the proof  
     * @param _pC Point C of the proof
     * @param _pubSignals Public signals (inputs) to verify
     * @return bool True if the proof is valid, false otherwise
     * @dev This is a view function, allowing free off-chain verification
     */
    function verifyProof(
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[3] calldata _pubSignals
    ) external view returns (bool);
}