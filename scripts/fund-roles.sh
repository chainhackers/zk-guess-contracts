#!/bin/bash
# Fund deployer + operator from funding wallet on Base mainnet.
set -e

source .env

FUNDING=0x0eE9931E50aaD6fB6Fb42BB61B8c2fCA6d757865
DEPLOYER=0x5A089E9Ca9AB8259d024CFBEe697B975cAea861d
OPERATOR=0xa3369e05999eC082f54817a0a991916780F8bdC4
KEYSTORE=$HOME/.zkguess-keystores/zkg-funding

echo "Funding:  $FUNDING  $(cast balance $FUNDING  --rpc-url $BASE_RPC_URL --ether) ETH"
echo "Deployer: $DEPLOYER  $(cast balance $DEPLOYER --rpc-url $BASE_RPC_URL --ether) ETH  -> +0.001"
echo "Operator: $OPERATOR  $(cast balance $OPERATOR --rpc-url $BASE_RPC_URL --ether) ETH  -> +0.002"
read -p "Proceed? (yes/no): " confirm
[ "$confirm" = "yes" ] || exit 0

cast send "$DEPLOYER" --value 0.001ether --keystore "$KEYSTORE" --rpc-url "$BASE_RPC_URL"
cast send "$OPERATOR" --value 0.002ether --keystore "$KEYSTORE" --rpc-url "$BASE_RPC_URL"

echo "Funding:  $(cast balance $FUNDING  --rpc-url $BASE_RPC_URL --ether) ETH"
echo "Deployer: $(cast balance $DEPLOYER --rpc-url $BASE_RPC_URL --ether) ETH"
echo "Operator: $(cast balance $OPERATOR --rpc-url $BASE_RPC_URL --ether) ETH"
