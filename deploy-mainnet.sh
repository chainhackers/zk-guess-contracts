#!/bin/bash
# Deploy to Base mainnet - BE CAREFUL!

# Load environment variables
source .env
echo "Deploying to Base mainnet..."

forge script script/Deploy.s.sol \
  --rpc-url $BASE_RPC_URL \
  --chain 8453 \
  --account deployer \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --verify \
  --verifier sourcify \
  -vvvv