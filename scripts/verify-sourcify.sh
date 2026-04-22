#!/bin/bash
set -e

# Verify contracts on Sourcify (works for any chain)
# Usage: ./verify-sourcify.sh [chain]
# Examples:
#   ./verify-sourcify.sh base
#   ./verify-sourcify.sh 80002  (Polygon Amoy)

CHAIN="${1:-base}"

VERIFIER="0xdcfba8812fd5a7427e24d0105c11c174d5b8fa34"
IMPL="0x7e512ba5e1a14460b9de1b546a98c59dab272e55"
PROXY="0xfa37cdcff862114c88c8e19b10b362d611a2c45f"

echo "=== Verifying on Sourcify (chain: $CHAIN) ==="

echo "Verifying Verifier..."
forge verify-contract $VERIFIER src/generated/GuessVerifier.sol:Groth16Verifier \
  --chain $CHAIN \
  --watch

echo "Verifying Implementation..."
forge verify-contract $IMPL src/GuessGame.sol:GuessGame \
  --chain $CHAIN \
  --watch

echo "Verifying Proxy..."
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,bytes)" \
  $IMPL \
  $(cast abi-encode "initialize(address,address,address)" \
    $VERIFIER \
    0x7f76caa7ba214bc589ae2f0283393039d93ab9e2 \
    0x7f76caa7ba214bc589ae2f0283393039d93ab9e2))

forge verify-contract $PROXY \
  lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --chain $CHAIN \
  --watch \
  --constructor-args $CONSTRUCTOR_ARGS

echo ""
echo "=== Sourcify Verification Complete ==="
echo "Verifier: $VERIFIER"
echo "Implementation: $IMPL"
echo "Proxy: $PROXY"
