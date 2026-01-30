// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

/**
 * @title ProofGenerator
 * @notice Abstract contract providing FFI-based ZK proof generation for tests
 * @dev Uses Node.js + snarkjs to generate Groth16 proofs on the fly
 */
abstract contract ProofGenerator is Test {
    /**
     * @notice Generate a ZK proof using FFI
     * @param secret The secret number
     * @param salt The salt used in commitment
     * @param guess The guess being verified
     * @return pA First part of proof
     * @return pB Second part of proof (2x2 matrix)
     * @return pC Third part of proof
     * @return pubSignals Public signals: [commitment, isCorrect, guess, maxNumber]
     */
    function generateProof(uint256 secret, uint256 salt, uint256 guess)
        internal
        returns (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory pubSignals)
    {
        return generateProofWithMaxNumber(secret, salt, guess, 65535);
    }

    /**
     * @notice Generate a ZK proof using FFI with custom maxNumber
     * @param secret The secret number
     * @param salt The salt used in commitment
     * @param guess The guess being verified
     * @param maxNumber The maximum number for the puzzle
     * @return pA First part of proof
     * @return pB Second part of proof (2x2 matrix)
     * @return pC Third part of proof
     * @return pubSignals Public signals: [commitment, isCorrect, guess, maxNumber]
     */
    function generateProofWithMaxNumber(uint256 secret, uint256 salt, uint256 guess, uint256 maxNumber)
        internal
        returns (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[4] memory pubSignals)
    {
        // Build FFI command
        string[] memory inputs = new string[](6);
        inputs[0] = "node";
        inputs[1] = "scripts/generate-proof.js";
        inputs[2] = vm.toString(secret);
        inputs[3] = vm.toString(salt);
        inputs[4] = vm.toString(guess);
        inputs[5] = vm.toString(maxNumber);

        // Execute FFI call
        bytes memory result = vm.ffi(inputs);

        // Parse JSON result
        string memory json = string(result);

        // Parse pA
        pA[0] = vm.parseJsonUint(json, ".pA[0]");
        pA[1] = vm.parseJsonUint(json, ".pA[1]");

        // Parse pB (note: 2D array with swapped coordinates for Solidity)
        pB[0][0] = vm.parseJsonUint(json, ".pB[0][0]");
        pB[0][1] = vm.parseJsonUint(json, ".pB[0][1]");
        pB[1][0] = vm.parseJsonUint(json, ".pB[1][0]");
        pB[1][1] = vm.parseJsonUint(json, ".pB[1][1]");

        // Parse pC
        pC[0] = vm.parseJsonUint(json, ".pC[0]");
        pC[1] = vm.parseJsonUint(json, ".pC[1]");

        // Parse pubSignals
        pubSignals[0] = vm.parseJsonUint(json, ".pubSignals[0]");
        pubSignals[1] = vm.parseJsonUint(json, ".pubSignals[1]");
        pubSignals[2] = vm.parseJsonUint(json, ".pubSignals[2]");
        pubSignals[3] = vm.parseJsonUint(json, ".pubSignals[3]");
    }

    /**
     * @notice Helper to compute commitment (for tests that need it without generating full proof)
     * @dev Uses FFI to call snarkjs which uses Poseidon hash
     * @param secret The secret number
     * @param salt The salt
     * @return commitment The Poseidon hash commitment
     */
    function computeCommitment(uint256 secret, uint256 salt) internal returns (bytes32 commitment) {
        // Generate proof just to get the commitment from pubSignals
        (,,, uint256[4] memory pubSignals) = generateProof(secret, salt, 0);
        return bytes32(pubSignals[0]);
    }
}
