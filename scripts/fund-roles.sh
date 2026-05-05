#!/bin/bash
# Fund deployer + operator from funding wallet on Base mainnet.
# Funding -> deployer (deploy gas) and funding -> operator (admin gas reserve).
# Run after the CEX -> funding withdrawal lands.
set -e

source .env

KEYSTORE_DIR="${KEYSTORE_DIR:-$HOME/.zkguess-keystores}"
FUNDING_KEYSTORE="$KEYSTORE_DIR/zkg-funding"

# Roles — addresses live in docs/security/wallet-topology.md and never change once funded.
FUNDING_ADDR=0x0eE9931E50aaD6fB6Fb42BB61B8c2fCA6d757865
DEPLOYER_ADDR=0x5A089E9Ca9AB8259d024CFBEe697B975cAea861d
OPERATOR_ADDR=0xa3369e05999eC082f54817a0a991916780F8bdC4

DEPLOYER_AMOUNT=${DEPLOYER_AMOUNT:-0.001ether}  # one-shot deploy gas budget
OPERATOR_AMOUNT=${OPERATOR_AMOUNT:-0.002ether}  # lifetime admin tx gas budget

if [ ! -f "$FUNDING_KEYSTORE" ]; then
    echo "ERROR: funding keystore not found at $FUNDING_KEYSTORE" >&2
    exit 1
fi
if [ -z "$BASE_RPC_URL" ]; then
    echo "ERROR: BASE_RPC_URL must be set (sourced from .env)" >&2
    exit 1
fi

echo "=== Pre-flight ==="
echo "RPC:      $BASE_RPC_URL"
echo "Funding:  $FUNDING_ADDR  (balance $(cast balance $FUNDING_ADDR --rpc-url $BASE_RPC_URL --ether) ETH)"
echo "Deployer: $DEPLOYER_ADDR  (balance $(cast balance $DEPLOYER_ADDR --rpc-url $BASE_RPC_URL --ether) ETH)  ← will receive $DEPLOYER_AMOUNT"
echo "Operator: $OPERATOR_ADDR  (balance $(cast balance $OPERATOR_ADDR --rpc-url $BASE_RPC_URL --ether) ETH)  ← will receive $OPERATOR_AMOUNT"
echo ""
read -p "Proceed with both transfers? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "=== Funding -> deployer ($DEPLOYER_AMOUNT) ==="
cast send "$DEPLOYER_ADDR" --value "$DEPLOYER_AMOUNT" \
    --keystore "$FUNDING_KEYSTORE" \
    --rpc-url "$BASE_RPC_URL"

echo ""
echo "=== Funding -> operator ($OPERATOR_AMOUNT) ==="
cast send "$OPERATOR_ADDR" --value "$OPERATOR_AMOUNT" \
    --keystore "$FUNDING_KEYSTORE" \
    --rpc-url "$BASE_RPC_URL"

echo ""
echo "=== Post-flight ==="
echo "Funding:  $(cast balance $FUNDING_ADDR --rpc-url $BASE_RPC_URL --ether) ETH"
echo "Deployer: $(cast balance $DEPLOYER_ADDR --rpc-url $BASE_RPC_URL --ether) ETH"
echo "Operator: $(cast balance $OPERATOR_ADDR --rpc-url $BASE_RPC_URL --ether) ETH"
