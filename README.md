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

- **GuessGame (Proxy)**: [`0xa05ebcf0f9aab5194c8a3ec8571a1d85d0a7f590`](https://basescan.org/address/0xa05ebcf0f9aab5194c8a3ec8571a1d85d0a7f590)
- Implementation: [`0x4a2d3b37b7a4b99ee523b3c47993876501d2d850`](https://basescan.org/address/0x4a2d3b37b7a4b99ee523b3c47993876501d2d850)
- Verifier: [`0xface0e73719e78e3bb020001fd10b62af9b3b6b8`](https://basescan.org/address/0xface0e73719e78e3bb020001fd10b62af9b3b6b8)
- Rewards: [`0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c`](https://basescan.org/address/0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c) — merkle-distributed rewards pool funded by forfeit collateral

### Previous deployment (permanently settled)

The previous proxy at `0xfa37cdcff862114c88c8e19b10b362d611a2c45f` was settled and renounced on 2026-04-16 (tx [`0xa35864ad...`](https://basescan.org/tx/0xa35864ad1d656a355bc5199b4aad2699f1689d82c4ce0333fa5e84c507eb61b1)) — all user funds were distributed and the contract is permanently sealed. Do not interact with it.

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
