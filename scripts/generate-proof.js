#!/usr/bin/env node
/**
 * Generate ZK proof for GuessGame v2 using snarkjs.
 * Usage: node scripts/generate-proof.js <number> <salt> <guess> <maxNumber> <puzzleId> <guesser>
 * Output: JSON with pA, pB, pC, pubSignals formatted for Solidity.
 *
 * Circuit inputs:  number, salt, guess, maxNumber, puzzleId, guesser
 * Public signals:  [commitment, isCorrect, guess, maxNumber, puzzleId, guesser]
 *
 * Artifacts: dev build copied from chainhackers/zk-guess-circuits via
 * `bun run copy-to-contracts`. See circuits/BUILD_INFO.txt for the source SHA.
 */

const snarkjs = require("snarkjs");
const path = require("path");
const fs = require("fs");

async function main() {
  const args = process.argv.slice(2);

  if (args.length !== 6) {
    console.error("Usage: node scripts/generate-proof.js <number> <salt> <guess> <maxNumber> <puzzleId> <guesser>");
    process.exit(1);
  }

  const [number, salt, guess, maxNumber, puzzleId, guesser] = args.map((x) => x.toString());

  const wasmPath = path.join(__dirname, "../circuits/guess.wasm");
  const zkeyPath = path.join(__dirname, "../circuits/guess_dev.zkey");

  if (!fs.existsSync(wasmPath)) {
    console.error(`WASM file not found: ${wasmPath}`);
    process.exit(1);
  }
  if (!fs.existsSync(zkeyPath)) {
    console.error(`zkey file not found: ${zkeyPath}`);
    process.exit(1);
  }

  // guesser is an Ethereum address; pass as decimal field element
  const guesserField = BigInt(guesser).toString();

  const input = {
    number: number,
    salt: salt,
    guess: guess,
    maxNumber: maxNumber,
    puzzleId: puzzleId,
    guesser: guesserField,
  };

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input,
    wasmPath,
    zkeyPath
  );

  // Format proof for Solidity (snarkjs orders pB inner pairs the EVM-friendly way after swap)
  const solidityProof = {
    pA: [proof.pi_a[0], proof.pi_a[1]],
    pB: [
      [proof.pi_b[0][1], proof.pi_b[0][0]],
      [proof.pi_b[1][1], proof.pi_b[1][0]]
    ],
    pC: [proof.pi_c[0], proof.pi_c[1]],
    pubSignals: publicSignals
  };

  console.log(JSON.stringify(solidityProof));
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
