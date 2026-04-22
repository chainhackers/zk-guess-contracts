#!/bin/bash
# Upgrade on Base mainnet

# Load environment variables
source .env

if [ -z "$PROXY_ADDRESS" ]; then
    echo "Error: PROXY_ADDRESS not set in .env"
    exit 1
fi

echo "==================================="
echo "  MAINNET UPGRADE - USE CAUTION"
echo "==================================="
echo ""
echo "Proxy address: $PROXY_ADDRESS"
echo "Using account: $DEPLOYER_ADDRESS"
echo ""
read -p "Are you sure you want to upgrade on mainnet? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Upgrade cancelled."
    exit 0
fi

forge script script/Upgrade.s.sol \
  --rpc-url $BASE_RPC_URL \
  --chain 8453 \
  --account deployer \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --verify \
  --verifier sourcify \
  -vvvv

# Extract new implementation address from broadcast log
IMPL_ADDRESS=$(jq -r '.transactions[] | select(.transactionType == "CREATE") | .contractAddress' \
  broadcast/Upgrade.s.sol/8453/run-latest.json)

if [ -n "$IMPL_ADDRESS" ] && [ "$IMPL_ADDRESS" != "null" ]; then
  echo ""
  echo "Verifying on Basescan: $IMPL_ADDRESS"
  forge verify-contract "$IMPL_ADDRESS" src/GuessGame.sol:GuessGame \
    --chain base \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --watch
else
  echo "Warning: could not extract implementation address from broadcast log"
fi
