#!/bin/bash
# Deploy to Base Sepolia testnet
set -e

# Load environment variables
source .env

if [ -z "$OWNER" ]; then
    echo "ERROR: OWNER env var is required (operator address; must differ from DEPLOYER_ADDRESS)." >&2
    exit 1
fi
if [ -z "$DEPLOYER_ADDRESS" ]; then
    echo "ERROR: DEPLOYER_ADDRESS env var is required." >&2
    exit 1
fi
if [ "${OWNER,,}" = "${DEPLOYER_ADDRESS,,}" ]; then
    echo "ERROR: OWNER must differ from DEPLOYER_ADDRESS — Phase B three-role separation." >&2
    exit 1
fi

echo "Deploying to Base Sepolia..."
echo "Deployer (one-shot, retired after this tx): $DEPLOYER_ADDRESS"
echo "Owner    (operator, post-deploy admin):     $OWNER"
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