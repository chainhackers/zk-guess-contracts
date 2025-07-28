# ZK Guess Contracts

Smart contracts for the ZK Guess number guessing game with on-chain Groth16 verification.

## Overview

This repository contains the Solidity smart contracts that power the ZK Guess game:

- **[GuessGame.sol](src/GuessGame.sol)** - Main game logic contract
- **[GuessVerifier.sol](src/generated/GuessVerifier.sol)** - Auto-generated Groth16 verifier (DO NOT EDIT)
- **[IGroth16Verifier.sol](src/interfaces/IGroth16Verifier.sol)** - Verifier interface
- **[IGuessGame.sol](src/interfaces/IGuessGame.sol)** - Game interface

## Setup

```bash
# Install dependencies
forge install

# Run tests
forge test

# Run tests with gas reporting
forge test --gas-report
```

## Deployment

First, set up your deployer keystore account:
```bash
# Import your private key (one-time setup)
cast wallet import deployer --interactive
```

Then use the deployment scripts:
```bash
# Deploy to local Anvil
./deploy-local.sh

# Deploy to Base Sepolia (testnet)
./deploy-sepolia.sh

# Deploy to Base mainnet (requires confirmation)
./deploy-mainnet.sh
```

## Testing

The test suite includes:
- Unit tests for core game mechanics
- Access control tests
- State transition tests

To run specific test files:
```bash
forge test --match-path test/GuessGame.t.sol
```

## Deployed Contracts (Base Mainnet)

- GuessVerifier: [`0x7A1FE6c7f77420fBa0557458Da7e785a286ee821`](https://basescan.org/address/0x7A1FE6c7f77420fBa0557458Da7e785a286ee821)
- GuessGame: [`0xEd36D47C48df4770b1C1F7d60F493301081AA392`](https://basescan.org/address/0xEd36D47C48df4770b1C1F7d60F493301081AA392)

## Architecture

The GuessGame contract uses the Groth16Verifier through composition to verify ZK proofs on-chain. The game flow is:

1. Creator posts a puzzle with a commitment to a secret number
2. Players submit guesses along with a stake
3. Creator responds with a ZK proof showing if the guess is correct
4. If correct: player wins bounty + stakes - creator rewards
5. If incorrect: stake is split between bounty growth and creator rewards

## Contract Verification

Contracts are automatically verified on Sourcify during deployment.

## Important Notes

- **NEVER** manually edit `src/generated/GuessVerifier.sol` - it's auto-generated from the circuits
- Run `bun run copy-to-contracts` in the circuits repo to update the verifier
- The verifier expects 2 public signals: `[commitment, isCorrect]`
- The build will show "unreachable code" warnings - these are expected due to the assembly code in the auto-generated verifier using early returns

## Gas Costs

- Puzzle creation: ~174k gas
- Guess submission: ~327k gas  
- Proof verification + response: ~245-595k gas (varies by outcome)

## License

MIT
