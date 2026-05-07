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

v2.1 — deployed 2026-05-07, block 45686113. Owner (operator) is
[`0xa3369e05999eC082f54817a0a991916780F8bdC4`](https://basescan.org/address/0xa3369e05999eC082f54817a0a991916780F8bdC4); deployer wallet
[`0x5A089E9Ca9AB8259d024CFBEe697B975cAea861d`](https://basescan.org/address/0x5A089E9Ca9AB8259d024CFBEe697B975cAea861d)
holds no admin authority. See [`docs/security/wallet-topology.md`](docs/security/wallet-topology.md).

- **GuessGame (Proxy)**: [`0x6F890B08fa4312135E1b4CF03929f8e389A866B4`](https://basescan.org/address/0x6F890B08fa4312135E1b4CF03929f8e389A866B4)
- Implementation: [`0x9217A110A5663f8685f0251a5892662b9f0Efb19`](https://basescan.org/address/0x9217A110A5663f8685f0251a5892662b9f0Efb19)
- Verifier: [`0x2772322a14Ff01c8df663AD13aaC3dC15aF1EfA9`](https://basescan.org/address/0x2772322a14Ff01c8df663AD13aaC3dC15aF1EfA9) — built from the [`v2-ceremony`](https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2-ceremony) phase-2 trusted-setup release
- Rewards: [`0xE9f7aE2A1E574d47CfD19dfB6B2059a31e127f01`](https://basescan.org/address/0xE9f7aE2A1E574d47CfD19dfB6B2059a31e127f01) — merkle-distributed rewards pool funded by forfeit collateral

### Previous deployments

v2 launch — deployed 2026-05-05, block 45605232. Superseded by v2.1 because the verifier was built from the dev-build zkey rather than the ceremony-final zkey (see [#46](https://github.com/chainhackers/zk-guess-contracts/issues/46)). Zero usage state, zero ETH; do not interact.

- GuessGame (Proxy): [`0xbA14152f40Df6673f316FD623313377Df6edD88A`](https://basescan.org/address/0xbA14152f40Df6673f316FD623313377Df6edD88A)
- Implementation: [`0xe9813127Fc5927289966DDBe1B0c36bC5190E0F4`](https://basescan.org/address/0xe9813127Fc5927289966DDBe1B0c36bC5190E0F4)
- Verifier: [`0xC6AACD8eAe397a92fA2175Dd0938e3A9c4f3582C`](https://basescan.org/address/0xC6AACD8eAe397a92fA2175Dd0938e3A9c4f3582C)
- Rewards: [`0x594A8b4fA394580f02c8C7B6450Fa5859F9b602F`](https://basescan.org/address/0x594A8b4fA394580f02c8C7B6450Fa5859F9b602F)

v1 (to be sealed via `settleAll(...)` as part of the v2 cutover; do not interact):

- GuessGame (Proxy): [`0xa05ebcf0f9aab5194c8a3ec8571a1d85d0a7f590`](https://basescan.org/address/0xa05ebcf0f9aab5194c8a3ec8571a1d85d0a7f590)
- Verifier: [`0xface0e73719e78e3bb020001fd10b62af9b3b6b8`](https://basescan.org/address/0xface0e73719e78e3bb020001fd10b62af9b3b6b8)
- Rewards: [`0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c`](https://basescan.org/address/0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c)

Pre-v1: proxy at `0xfa37cdcff862114c88c8e19b10b362d611a2c45f` was settled and renounced on 2026-04-16 (tx [`0xa35864ad...`](https://basescan.org/tx/0xa35864ad1d656a355bc5199b4aad2699f1689d82c4ce0333fa5e84c507eb61b1)) — all user funds were distributed and the contract is permanently sealed.

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
- The deployed v2 verifier corresponds to circuits release [`v2-ceremony`](https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2-ceremony) — phase-2 trusted setup, 5 contributors + Bitcoin-block beacon (sealed 2026-04-28). See [`SECURITY.md`](SECURITY.md) and [`docs/security/not-a-mixer.md`](docs/security/not-a-mixer.md).

## Gas Costs

- Puzzle creation: ~174k gas
- Guess submission: ~327k gas  
- Proof verification + response: ~245-595k gas (varies by outcome)

## Security

- Disclosure contact, bug bounty terms, and admin-authority disclosure: [`SECURITY.md`](SECURITY.md).
- Threat model and non-mixer explainer (the body submitted to Blockaid): [`docs/security/not-a-mixer.md`](docs/security/not-a-mixer.md).
- Wallet topology — which addresses hold which roles, and what each is allowed to do: [`docs/security/wallet-topology.md`](docs/security/wallet-topology.md).

## License

MIT
