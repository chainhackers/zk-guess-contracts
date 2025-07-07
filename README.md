# ZK Guess Contracts

On-chain game logic where players prove their guesses without revealing the secret number.

## Contracts

- `GuessGame.sol` - Main game logic
- `GuessVerifier.sol` - Auto-generated Groth16 verifier (DO NOT EDIT)

## Quick Start

```bash
# Install dependencies
forge install

# Run tests
forge test

# Run slow tests (generates real proofs)
SLOW_TESTS=true forge test

# Deploy to Base testnet
forge script script/Deploy.s.sol --rpc-url base-sepolia --broadcast
```

## Game Flow

1. **Creator** commits to hidden number with bounty
2. **Players** submit guesses with stakes  
3. **Creator** proves guesses right/wrong via ZK
4. **Winner** takes bounty + accumulated stakes

## License

MIT
