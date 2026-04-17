#!/bin/bash
set -e

# Deterministic deployment to Base mainnet using raw calldata
# This bypasses forge's simulation issues with CREATE2 factories
# Usage: ./deploy-base.sh

RPC_URL="https://mainnet.base.org"
FACTORY="0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7"
SALT="c0c53b8b00000000000000000000000000000000000000000000000000000002"
TREASURY="0x7f76caa7ba214bc589ae2f0283393039d93ab9e2"
OWNER="0x7f76caa7ba214bc589ae2f0283393039d93ab9e2"

echo "=== Deploying to Base Mainnet ==="
echo ""
echo "WARNING: This is a MAINNET deployment!"
echo ""
echo "Salt: 0x$SALT"
echo "Treasury: $TREASURY"
echo "Owner: $OWNER"
echo ""
read -p "Continue with mainnet deployment? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
fi
echo ""

# Get bytecodes from compiled artifacts (without 0x prefix for concatenation)
VERIFIER_BYTECODE=$(jq -r '.bytecode.object' out/GuessVerifier.sol/Groth16Verifier.json | sed 's/^0x//')
IMPL_BYTECODE=$(jq -r '.bytecode.object' out/GuessGame.sol/GuessGame.json | sed 's/^0x//')

# Compute CREATE2 addresses
compute_create2() {
    local INIT_CODE="0x$1"
    local INIT_HASH=$(cast keccak "$INIT_CODE")
    local ADDR=$(cast keccak "0xff${FACTORY:2}${SALT}${INIT_HASH:2}" | cut -c27-)
    echo "0x$ADDR"
}

VERIFIER_ADDR=$(compute_create2 "$VERIFIER_BYTECODE")
IMPL_ADDR=$(compute_create2 "$IMPL_BYTECODE")

echo "Predicted addresses:"
echo "  Verifier: $VERIFIER_ADDR"
echo "  Implementation: $IMPL_ADDR"

# Check and deploy Verifier
VERIFIER_CODE=$(cast code $VERIFIER_ADDR --rpc-url $RPC_URL)
if [ "$VERIFIER_CODE" != "0x" ]; then
    echo "Verifier already deployed at $VERIFIER_ADDR"
else
    echo "Deploying Verifier..."
    CALLDATA="0x${SALT}${VERIFIER_BYTECODE}"
    cast send $FACTORY $CALLDATA \
      --account deployer \
      --rpc-url $RPC_URL \
      --gas-limit 600000 \
      --timeout 120 \
      --rpc-timeout 60
    sleep 3
    CODE=$(cast code $VERIFIER_ADDR --rpc-url $RPC_URL | head -c 20)
    if [ "$CODE" != "0x" ]; then
        echo "Verifier deployed at $VERIFIER_ADDR"
    else
        echo "Verifier deployment failed"
        exit 1
    fi
fi

# Check and deploy Implementation
IMPL_CODE=$(cast code $IMPL_ADDR --rpc-url $RPC_URL)
if [ "$IMPL_CODE" != "0x" ]; then
    echo "Implementation already deployed at $IMPL_ADDR"
else
    echo "Deploying Implementation..."
    CALLDATA="0x${SALT}${IMPL_BYTECODE}"
    cast send $FACTORY $CALLDATA \
      --account deployer \
      --rpc-url $RPC_URL \
      --gas-limit 5000000 \
      --timeout 120 \
      --rpc-timeout 60
    sleep 3
    CODE=$(cast code $IMPL_ADDR --rpc-url $RPC_URL | head -c 20)
    if [ "$CODE" != "0x" ]; then
        echo "Implementation deployed at $IMPL_ADDR"
    else
        echo "Implementation deployment failed"
        exit 1
    fi
fi

# Build and deploy Proxy
echo "Building proxy bytecode..."
PROXY_CREATION_CODE=$(jq -r '.bytecode.object' out/ERC1967Proxy.sol/ERC1967Proxy.json | sed 's/^0x//')

# Encode constructor args for ERC1967Proxy(address impl, bytes memory data)
VERIFIER_PADDED=$(printf '%064s' "${VERIFIER_ADDR:2}" | tr ' ' '0')
TREASURY_PADDED=$(printf '%064s' "${TREASURY:2}" | tr ' ' '0')
OWNER_PADDED=$(printf '%064s' "${OWNER:2}" | tr ' ' '0')
IMPL_PADDED=$(printf '%064s' "${IMPL_ADDR:2}" | tr ' ' '0')

# Initialize selector: 0xc0c53b8b for initialize(address,address,address)
INIT_DATA="c0c53b8b${VERIFIER_PADDED}${TREASURY_PADDED}${OWNER_PADDED}"
INIT_DATA_LENGTH=$(printf '%064x' $((${#INIT_DATA} / 2)))

CONSTRUCTOR_ARGS="${IMPL_PADDED}0000000000000000000000000000000000000000000000000000000000000040${INIT_DATA_LENGTH}${INIT_DATA}"
PROXY_BYTECODE="${PROXY_CREATION_CODE}${CONSTRUCTOR_ARGS}"

PROXY_ADDR=$(compute_create2 "$PROXY_BYTECODE")
echo "  Proxy: $PROXY_ADDR"

PROXY_CODE=$(cast code $PROXY_ADDR --rpc-url $RPC_URL)
if [ "$PROXY_CODE" != "0x" ]; then
    echo "Proxy already deployed at $PROXY_ADDR"
else
    echo "Deploying Proxy..."
    CALLDATA="0x${SALT}${PROXY_BYTECODE}"
    cast send $FACTORY $CALLDATA \
      --account deployer \
      --rpc-url $RPC_URL \
      --gas-limit 1000000 \
      --timeout 120 \
      --rpc-timeout 60
    sleep 3
    CODE=$(cast code $PROXY_ADDR --rpc-url $RPC_URL | head -c 20)
    if [ "$CODE" != "0x" ]; then
        echo "Proxy deployed at $PROXY_ADDR"
    else
        echo "Proxy deployment failed"
        exit 1
    fi
fi

echo ""
echo "=== Verifying Deployment ==="
ACTUAL_OWNER=$(cast call $PROXY_ADDR "owner()(address)" --rpc-url $RPC_URL)
echo "Owner: $ACTUAL_OWNER"

echo ""
echo "=== Base Mainnet Deployment Complete ==="
echo "Verifier: $VERIFIER_ADDR"
echo "Implementation: $IMPL_ADDR"
echo "Proxy: $PROXY_ADDR"
