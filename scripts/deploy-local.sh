#!/bin/bash
# Deploy to local Anvil node
set -e

# Default Anvil deterministic accounts: account[0] is the deployer, account[1] is OWNER.
# Override with env if needed (must differ — three-role rule mirrors mainnet).
: "${DEPLOYER_ADDRESS:=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
: "${ANVIL_DEPLOYER_KEY:=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
: "${OWNER:=0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"

if [ "${OWNER,,}" = "${DEPLOYER_ADDRESS,,}" ]; then
    echo "ERROR: OWNER must differ from DEPLOYER_ADDRESS." >&2
    exit 1
fi

echo "Deploying to local Anvil..."
echo "Deployer: $DEPLOYER_ADDRESS"
echo "Owner:    $OWNER"
echo ""

OWNER="$OWNER" DEPLOYER_ADDRESS="$DEPLOYER_ADDRESS" forge script script/Deploy.s.sol \
  --rpc-url http://localhost:8545 \
  --private-key $ANVIL_DEPLOYER_KEY \
  --broadcast \
  -vvv