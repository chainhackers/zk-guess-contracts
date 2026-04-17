# Deployment Guide

## Overview

This project supports two deployment methods:

1. **Standard Deployment** (`Deploy.s.sol`) - Simple deployment, addresses vary per chain
2. **Deterministic Deployment** (`DeployDeterministic.s.sol`) - Same addresses across all EVM chains

## Prerequisites

```bash
# Install dependencies
forge install

# Set up your deployer account (one-time)
cast wallet import deployer --interactive
```

## Environment Setup

Create `.env` file:

```bash
# Required for all deployments
TREASURY_ADDRESS=0x...  # Address to receive slashed collateral

# Required for deterministic deployment
DEPLOY_SALT=0x...  # 32-byte hex string, keep same across all chains

# RPC URLs
BASE_SEPOLIA_RPC=https://sepolia.base.org
BASE_MAINNET_RPC=https://mainnet.base.org
OPTIMISM_RPC=https://mainnet.optimism.io
ARBITRUM_RPC=https://arb1.arbitrum.io/rpc
```

## Standard Deployment

Use when you only need to deploy to one chain or don't need matching addresses.

```bash
# Load environment
source .env

# Deploy to Base Sepolia (testnet)
forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC \
  --account deployer \
  --broadcast \
  --verify

# Deploy to Base Mainnet
forge script script/Deploy.s.sol \
  --rpc-url $BASE_MAINNET_RPC \
  --account deployer \
  --broadcast \
  --verify
```

## Deterministic Cross-Chain Deployment

Use when you need the **same contract addresses** on multiple chains.

### How It Works

Uses CREATE2 via [Safe Singleton Factory](https://github.com/safe-global/safe-singleton-factory) (`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`) which is deployed on 100+ EVM chains.

Address formula:
```
address = keccak256(0xff + factory + salt + keccak256(initCode))[12:]
```

Same `factory + salt + initCode` = **same address on any chain**.

### Generate Salt

```bash
# Option 1: From a string (reproducible)
export DEPLOY_SALT=0x$(echo -n "zk-guess-mainnet-v1" | sha256sum | cut -d' ' -f1)

# Option 2: Random (save this!)
export DEPLOY_SALT=0x$(openssl rand -hex 32)

# Save to .env
echo "DEPLOY_SALT=$DEPLOY_SALT" >> .env
```

### Pre-compute Addresses (Dry Run)

```bash
# Simulate deployment to see addresses without spending gas
forge script script/DeployDeterministic.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC \
  -vvv
```

Output:
```
Predicted addresses:
  Verifier: 0x...
  Implementation: 0x...
  Proxy: 0x...
```

### Deploy to Multiple Chains

```bash
source .env

# Deploy to Base
forge script script/DeployDeterministic.s.sol \
  --rpc-url $BASE_MAINNET_RPC \
  --account deployer \
  --broadcast \
  --verify

# Deploy to Optimism (same addresses!)
forge script script/DeployDeterministic.s.sol \
  --rpc-url $OPTIMISM_RPC \
  --account deployer \
  --broadcast \
  --verify

# Deploy to Arbitrum (same addresses!)
forge script script/DeployDeterministic.s.sol \
  --rpc-url $ARBITRUM_RPC \
  --account deployer \
  --broadcast \
  --verify
```

### Requirements for Same Addresses

| Requirement | Notes |
|-------------|-------|
| Same `DEPLOY_SALT` | Store securely, reuse across chains |
| Same `TREASURY_ADDRESS` | Must be identical, or use a chain-agnostic address |
| Same contract bytecode | Same compiler version + settings |
| Same OpenZeppelin version | Affects proxy bytecode |

### Deployment Order

The script deploys in this order (required for address determinism):

1. **Verifier** - no dependencies
2. **Implementation** - no dependencies
3. **Proxy** - depends on verifier + impl addresses

### Verify Deployment

After deploying to each chain:

```bash
# Check proxy points to correct implementation
cast call $PROXY_ADDRESS "owner()" --rpc-url $RPC_URL
cast call $PROXY_ADDRESS "treasury()" --rpc-url $RPC_URL
cast call $PROXY_ADDRESS "verifier()" --rpc-url $RPC_URL
```

## Upgrading

The proxy uses UUPS pattern. Only the owner can upgrade:

```bash
# Deploy new implementation
NEW_IMPL=$(forge create src/GuessGame.sol:GuessGame --account deployer --rpc-url $RPC_URL)

# Upgrade proxy
cast send $PROXY_ADDRESS "upgradeToAndCall(address,bytes)" $NEW_IMPL 0x \
  --account deployer \
  --rpc-url $RPC_URL
```

## Contract Verification

### Sourcify (Recommended)

```bash
forge verify-contract $PROXY_ADDRESS GuessGame \
  --verifier sourcify \
  --chain-id 8453
```

### Etherscan/Basescan

```bash
forge verify-contract $PROXY_ADDRESS GuessGame \
  --chain base \
  --verifier etherscan \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
```

## Troubleshooting

### "EvmError: Revert" on CREATE2

The contract may already be deployed at that address. Check:
```bash
cast code $PREDICTED_ADDRESS --rpc-url $RPC_URL
```

### Different Addresses on Different Chains

Ensure:
1. Same `DEPLOY_SALT`
2. Same `TREASURY_ADDRESS`
3. Same Solidity compiler version (`forge --version`)
4. Same OpenZeppelin contracts version

### Safe Singleton Factory Not Deployed

On some newer chains, the factory may not exist yet. Check:
```bash
cast code 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7 --rpc-url $RPC_URL
```

If empty, see [Safe's deployment guide](https://github.com/safe-global/safe-singleton-factory#deploying-the-factory).
