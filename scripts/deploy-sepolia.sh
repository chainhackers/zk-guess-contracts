#!/bin/bash
# Deploy to Base Sepolia testnet

# Load environment variables
source .env

echo "Deploying to Base Sepolia..."
echo "Using account: $DEPLOYER_ADDRESS"
echo ""

forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --chain 84532 \
  --account deployer \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --verify \
  --verifier sourcify \
  -vvvv