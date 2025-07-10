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

```bash
# Deploy to local network
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# Deploy to Base testnet
forge script script/Deploy.s.sol --rpc-url $BASE_TESTNET_RPC --private-key $PRIVATE_KEY --broadcast --verify
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

## Important Notes

- **NEVER** manually edit `GuessVerifier.sol` - it's auto-generated from the circuits
- Run `bun run copy-to-contracts` in the circuits repo to update the verifier
- The verifier expects 2 public signals: `[commitment, isCorrect]`

## Gas Costs

- Puzzle creation: ~172k gas
- Guess submission: ~325k gas  
- Proof verification: TBD (depends on actual proofs)

## License

MIT
