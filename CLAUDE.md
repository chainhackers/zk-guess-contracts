# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Development Commands

### Formatting
```bash
# Check formatting
forge fmt --check

# Fix formatting
forge fmt
```

**Always run `forge fmt` before commits.** A pre-commit hook is configured to enforce this.

### Building and Testing
```bash
# Build contracts
forge build

# Run all tests (fast, excludes integration)
forge test --no-match-path "test/integration/*"

# Run all tests including slow FFI integration tests
forge test --ffi

# Run tests with gas reporting
forge test --gas-report

# Run specific test file
forge test --match-path test/GuessGame.t.sol

# Run specific test function
forge test --match-test test_CreatePuzzle
```

### Deployment
```bash
# Deploy to local Anvil (ensure anvil is running)
./deploy-local.sh

# Deploy to Base Sepolia testnet
./deploy-sepolia.sh

# Deploy to Base mainnet (requires confirmation)
./deploy-mainnet.sh
```

### Contract Verification
```bash
# Verify on Sourcify
forge verify-contract --verifier sourcify --chain 8453 <CONTRACT_ADDRESS> GuessGame

# Verify on Basescan (requires API key in .env)
forge verify-contract --verifier-url https://api.basescan.org/api --etherscan-api-key <API_KEY> --chain 8453 <CONTRACT_ADDRESS> GuessGame
```

## Architecture Overview

This is a ZK-based number guessing game implemented in Solidity with on-chain Groth16 proof verification.

### Core Contracts

1. **src/generated/GuessVerifier.sol** - Auto-generated Groth16 verifier
   - **NEVER EDIT THIS FILE MANUALLY**
   - Generated from ZK circuits in a separate repository
   - Updated via `bun run copy-to-contracts` in the circuits repo
   - Expects 2 public signals: `[commitment, isCorrect]`
   - Located in `src/generated/` to indicate it's auto-generated
   - Causes "unreachable code" warnings due to assembly early returns (this is expected)

2. **GuessGame.sol** - Main game logic
   - Inherits from Groth16Verifier for proof verification
   - Manages puzzles, challenges, and prize distribution
   - Key state mappings: `puzzles`, `challenges`, `challengeToPuzzle`

3. **IGuessGame.sol** - Interface defining all structures and functions
   - Defines `Puzzle` and `Challenge` structs
   - Contains all events and custom errors

### Game Flow

1. **Puzzle Creation**: Creator posts a commitment to a secret number with initial bounty
2. **Guess Submission**: Players submit guesses with required stake
3. **Challenge Response**: Creator provides ZK proof showing if guess is correct
4. **Prize Distribution**: 
   - Correct guess: Player wins bounty + all stakes
   - Incorrect guess: Player's stake added to bounty

### Key Implementation Details

- Minimum bounty: 0.001 ether
- Creator never reveals the actual secret number
- ZK proofs verify both knowledge of secret and correctness of guess
- Bounty grows by configurable percentage from failed guesses
- Access control ensures only puzzle creator can respond to challenges
- **IMPORTANT**: Cannot use `address(this).balance` for prize calculations as the contract holds funds for multiple puzzles
- Must track each puzzle's funds separately using state variables (bounty, totalStaked, creatorReward)

## Testing Approach

Tests use Foundry's testing framework with the following patterns:
- Unit tests for each major function
- Access control verification
- State transition testing
- Mock proofs for testing (actual ZK proofs generated off-chain)
- Use `vm.prank()` for simulating different actors
- Use `vm.expectRevert()` for testing error conditions

## Deployment Configuration

- Uses Foundry's script system with broadcast functionality
- Keystore-based deployment (import key with `cast wallet import deployer`)
- Environment variables loaded from `.env` file
- Supports Base Sepolia (testnet) and Base mainnet
- Contract verification integrated into deployment scripts