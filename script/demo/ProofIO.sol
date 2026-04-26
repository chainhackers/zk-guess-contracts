// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";

/// @notice Reads a snarkjs-shaped proof JSON (matching scripts/generate-proof.js output)
/// from disk into the Groth16 + v2-pubSignals structures the contract expects.
/// Lets the demo scripts decouple proof generation from broadcast — the operator runs
/// `node scripts/generate-proof.js ... > /tmp/proof.json` once, then any number of
/// `forge script` invocations can re-broadcast against it.
abstract contract ProofIO is Script {
    function _readProofFrom(string memory path)
        internal
        view
        returns (uint256[2] memory pA, uint256[2][2] memory pB, uint256[2] memory pC, uint256[6] memory pubSignals)
    {
        string memory json = vm.readFile(path);
        pA[0] = vm.parseJsonUint(json, ".pA[0]");
        pA[1] = vm.parseJsonUint(json, ".pA[1]");
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
}
