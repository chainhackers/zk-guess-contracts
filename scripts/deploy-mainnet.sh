#!/bin/bash
# Deploy Verifier + Rewards + GuessGame (proxy) to Base mainnet
set -e

source .env

echo "==================================="
echo "  MAINNET DEPLOYMENT - USE CAUTION"
echo "==================================="
echo ""
echo "Deployer: $DEPLOYER_ADDRESS"
echo ""
read -p "Proceed with mainnet deployment? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
fi

forge script script/Deploy.s.sol \
  --rpc-url $BASE_RPC_URL \
  --chain 8453 \
  --account deployer \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --verify \
  --verifier sourcify \
  -vvvv

# Extract deployed addresses from broadcast log
BROADCAST="broadcast/Deploy.s.sol/8453/run-latest.json"
if [ -f "$BROADCAST" ]; then
    echo ""
    echo "=== Deployed addresses ==="
    VERIFIER_ADDR=$(jq -r '.transactions[] | select(.contractName == "Groth16Verifier") | .contractAddress' "$BROADCAST")
    REWARDS_ADDR=$(jq -r '.transactions[] | select(.contractName == "Rewards") | .contractAddress' "$BROADCAST")
    IMPL_ADDR=$(jq -r '.transactions[] | select(.contractName == "GuessGame") | .contractAddress' "$BROADCAST")
    PROXY_ADDR=$(jq -r '.transactions[] | select(.contractName == "ERC1967Proxy") | .contractAddress' "$BROADCAST")
    echo "  Verifier:       $VERIFIER_ADDR"
    echo "  Rewards:        $REWARDS_ADDR"
    echo "  Implementation: $IMPL_ADDR"
    echo "  Proxy:          $PROXY_ADDR"
    echo ""
    echo "Next: update .env with PROXY_ADDRESS=$PROXY_ADDR and REWARDS_ADDRESS=$REWARDS_ADDR, then update README.md"

    # Verify each on Basescan if API key is set
    if [ -n "$ETHERSCAN_API_KEY" ]; then
        echo ""
        echo "=== Verifying on Basescan ==="
        forge verify-contract "$IMPL_ADDR" src/GuessGame.sol:GuessGame \
            --chain base --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" --watch || true
        forge verify-contract "$REWARDS_ADDR" src/Rewards.sol:Rewards \
            --chain base --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --constructor-args "$(cast abi-encode 'constructor(address)' $DEPLOYER_ADDRESS)" --watch || true
    fi
else
    echo "Warning: broadcast log not found at $BROADCAST"
fi
