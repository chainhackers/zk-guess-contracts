#!/bin/bash
set -e

# Verify contracts on Basescan
# Usage: BASESCAN_API_KEY=... ./verify-basescan.sh

BASESCAN_API_KEY="${BASESCAN_API_KEY:-EKBPCN8DVJN89ZH4RKC3PP73BAC7VEB3BD}"

VERIFIER="0xdcfba8812fd5a7427e24d0105c11c174d5b8fa34"
IMPL="0x228c6EF418C28c46A0b97A7f1f89fE472dA2Ad1c"
PROXY="0xfa37cdcff862114c88c8e19b10b362d611a2c45f"

echo "=== Verifying on Basescan ==="

echo "Verifying Verifier..."
forge verify-contract $VERIFIER src/generated/GuessVerifier.sol:Groth16Verifier \
  --chain base \
  --etherscan-api-key $BASESCAN_API_KEY \
  --watch

echo "Verifying Implementation..."
forge verify-contract $IMPL src/GuessGame.sol:GuessGame \
  --chain base \
  --etherscan-api-key $BASESCAN_API_KEY \
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
  --chain base \
  --etherscan-api-key $BASESCAN_API_KEY \
  --watch \
  --constructor-args $CONSTRUCTOR_ARGS

echo ""
echo "=== Verification Complete ==="
echo "Verifier: https://basescan.org/address/$VERIFIER#code"
echo "Implementation: https://basescan.org/address/$IMPL#code"
echo "Proxy: https://basescan.org/address/$PROXY#code"
