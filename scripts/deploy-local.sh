#!/bin/bash
# Deploy to local Anvil node

echo "Deploying to local network..."

forge script script/Deploy.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast \
  -vvv