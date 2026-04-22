#!/bin/bash
# Upgrade on Base Sepolia testnet

# Load environment variables
source .env

if [ -z "$PROXY_ADDRESS" ]; then
    echo "Error: PROXY_ADDRESS not set in .env"
    exit 1
fi

echo "Upgrading proxy on Base Sepolia..."
echo "Proxy address: $PROXY_ADDRESS"
echo "Using account: $DEPLOYER_ADDRESS"
echo ""

forge script script/Upgrade.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --chain 84532 \
  --account deployer \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --verify \
  --verifier sourcify \
  -vvvv
