#!/bin/bash
# Upgrade on local Anvil

# Load environment variables
source .env

if [ -z "$PROXY_ADDRESS" ]; then
    echo "Error: PROXY_ADDRESS not set in .env"
    exit 1
fi

echo "Upgrading proxy at: $PROXY_ADDRESS"
echo ""

# Use anvil's first default test account
forge script script/Upgrade.s.sol \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast \
  -vvvv
