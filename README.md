# ZK Guess Contracts

Smart contracts for the ZK Guess number guessing game with on-chain Groth16 verification.

## Overview

This repository contains the Solidity smart contracts that power the ZK Guess game:

- **[GuessGame.sol](src/GuessGame.sol)** - Main game logic contract
- **[GuessVerifier.sol](src/GuessVerifier.sol)** - Auto-generated Groth16 verifier (DO NOT EDIT)
- **[IGuessGame.sol](src/interfaces/IGuessGame.sol)** - Interface defining game structures and functions

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

## Architecture

The GuessGame contract inherits from the auto-generated Groth16Verifier to efficiently verify ZK proofs on-chain. The game flow is:

1. Creator posts a puzzle with a commitment to a secret number
2. Players submit guesses along with a stake
3. Creator responds with a ZK proof showing if the guess is correct
4. If correct: player wins bounty + all stakes
5. If incorrect: player's stake is added to the bounty

## Contract Verification

After deployment, verify your contract using Sourcify:

```bash
forge verify-contract --verifier sourcify --chain 8453 <CONTRACT_ADDRESS> GuessGame
```

## Important Notes

- **NEVER** manually edit `src/generated/GuessVerifier.sol` - it's auto-generated from the circuits
- Run `bun run copy-to-contracts` in the circuits repo to update the verifier
- The verifier expects 2 public signals: `[commitment, isCorrect]`
- The build will show "unreachable code" warnings - these are expected due to the assembly code in the auto-generated verifier using early returns

## Gas Costs

- Puzzle creation: ~172k gas
- Guess submission: ~325k gas  
- Proof verification: TBD (depends on actual proofs)

## License

MIT
