#!/usr/bin/env node
/**
 * Generate ZK proof for GuessGame using snarkjs
 * Usage: node scripts/generate-proof.js <number> <salt> <guess>
 * Output: JSON with pA, pB, pC, pubSignals formatted for Solidity
 *
 * Circuit inputs: number, salt, guess
 * Circuit outputs (public signals): commitment, isCorrect, guess
 */

const snarkjs = require("snarkjs");
const path = require("path");
const fs = require("fs");

async function main() {
  const args = process.argv.slice(2);

  if (args.length !== 3) {
    console.error("Usage: node generate-proof.js <number> <salt> <guess>");
    process.exit(1);
  }

  const [number, salt, guess] = args.map((x) => x.toString());

  // Paths to circuit artifacts
  const wasmPath = path.join(__dirname, "../circuits/guess.wasm");
  const zkeyPath = path.join(__dirname, "../circuits/guess_final.zkey");

  // Verify files exist
  if (!fs.existsSync(wasmPath)) {
    console.error(`WASM file not found: ${wasmPath}`);
    process.exit(1);
  }
  if (!fs.existsSync(zkeyPath)) {
    console.error(`zkey file not found: ${zkeyPath}`);
    process.exit(1);
  }

  // Circuit inputs (commitment is computed by circuit, not provided)
  const input = {
    number: number,
    salt: salt,
    guess: guess
  };

  // Generate the proof
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input,
    wasmPath,
    zkeyPath
  );

  // Format proof for Solidity (convert to BigInt strings)
  // pA: [x, y]
  // pB: [[x1, x2], [y1, y2]] - note: swapped order for Solidity
  // pC: [x, y]
  // pubSignals: [commitment, isCorrect, guess]
  const solidityProof = {
    pA: [proof.pi_a[0], proof.pi_a[1]],
    pB: [
      [proof.pi_b[0][1], proof.pi_b[0][0]], // Swap inner coordinates
      [proof.pi_b[1][1], proof.pi_b[1][0]]
    ],
    pC: [proof.pi_c[0], proof.pi_c[1]],
    pubSignals: publicSignals
  };

  // Output as JSON
  console.log(JSON.stringify(solidityProof));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
