// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

/**
 * @title ProofGenerator
 * @notice Abstract contract providing FFI-based ZK proof generation for v2 circuit tests.
 * @dev Drives Node.js + snarkjs against the dev artifacts at circuits/guess.wasm and
 *      circuits/guess_dev.zkey to produce real Groth16 proofs that satisfy the v2 verifier.
 */
abstract contract ProofGenerator is Test {
    /**
     * @notice Generate a v2 ZK proof using FFI with default maxNumber (65535).
     * @param secret The secret number
     * @param salt The salt used in commitment
     * @param guess The guess being verified
     * @param puzzleId The puzzleId bound into the proof (must match contract puzzleId)
     * @param guesserAddr The guesser address bound into the proof (must match challenge.guesser)
     * @return pA First part of proof
     * @return pB Second part of proof (2x2 matrix)
     * @return pC Third part of proof
     * @return pubSignals Public signals: [commitment, isCorrect, guess, maxNumber, puzzleId, guesser]
     */
    function generateProof(uint256 secret, uint256 salt, uint256 guess, uint256 puzzleId, address guesserAddr)
        internal
        returns (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[6] memory pubSignals)
    {
        return generateProofWithMaxNumber(secret, salt, guess, 65535, puzzleId, guesserAddr);
    }

    /**
     * @notice Generate a v2 ZK proof using FFI with explicit maxNumber.
     */
    function generateProofWithMaxNumber(
        uint256 secret,
        uint256 salt,
        uint256 guess,
        uint256 maxNumber,
        uint256 puzzleId,
        address guesserAddr
    )
        internal
        returns (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[6] memory pubSignals)
    {
        string[] memory inputs = new string[](8);
        inputs[0] = "node";
        inputs[1] = "scripts/generate-proof.js";
        inputs[2] = vm.toString(secret);
        inputs[3] = vm.toString(salt);
        inputs[4] = vm.toString(guess);
        inputs[5] = vm.toString(maxNumber);
        inputs[6] = vm.toString(puzzleId);
        inputs[7] = vm.toString(guesserAddr);

        bytes memory result = vm.ffi(inputs);
        string memory json = string(result);

        pA[0] = vm.parseJsonUint(json, ".pA[0]");
        pA[1] = vm.parseJsonUint(json, ".pA[1]");

        // pB inner pairs are EVM-friendly already (script swaps once)
        pB[0][0] = vm.parseJsonUint(json, ".pB[0][0]");
        pB[0][1] = vm.parseJsonUint(json, ".pB[0][1]");
        pB[1][0] = vm.parseJsonUint(json, ".pB[1][0]");
        pB[1][1] = vm.parseJsonUint(json, ".pB[1][1]");

        pC[0] = vm.parseJsonUint(json, ".pC[0]");
        pC[1] = vm.parseJsonUint(json, ".pC[1]");

        for (uint256 i = 0; i < 6; i++) {
            pubSignals[i] = vm.parseJsonUint(json, string.concat(".pubSignals[", vm.toString(i), "]"));
        }
    }

    /**
     * @notice Helper to compute the commitment (Poseidon([DOMAIN_TAG, secret, salt])) via FFI.
     * @dev Generates a throwaway proof just to read commitment back out of public signals;
     *      `puzzleId` and `guesser` bindings are irrelevant for this lookup since the contract
     *      only consumes `pubSignals[0]` here.
     */
    function computeCommitment(uint256 secret, uint256 salt) internal returns (bytes32 commitment) {
        (,,, uint256[6] memory pubSignals) = generateProof(secret, salt, secret, 0, address(0));
        return bytes32(pubSignals[0]);
    }
}
