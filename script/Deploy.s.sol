// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/GuessGame.sol";
import "../src/Rewards.sol";
import "../src/generated/GuessVerifier.sol";

/// @title Deploy
/// @notice Deploys Verifier + Rewards + GuessGame (proxy); Rewards is GuessGame's treasury.
/// @dev Reads `OWNER` and `DEPLOYER_ADDRESS` from the environment and refuses to broadcast
///      when the two coincide — enforces the Phase B three-role separation (deployer is a
///      one-shot keypair; the operator/OWNER never deploys and never plays).
contract DeployScript is Script {
    /// @notice Pure deploy logic, parameterized by `owner`. Both the Rewards constructor and
    ///         GuessGame.initialize receive `owner` directly, so the deployer EOA never holds
    ///         ownership at any point — no `transferOwnership` call is needed.
    /// @dev Public so tests can invoke it without going through `vm.startBroadcast`.
    function deploy(address owner)
        public
        returns (Groth16Verifier verifier, Rewards rewards, GuessGame impl, address proxy)
    {
        verifier = new Groth16Verifier();
        rewards = new Rewards(owner);
        impl = new GuessGame();

        bytes memory initData = abi.encodeCall(GuessGame.initialize, (address(verifier), address(rewards), owner));
        proxy = address(new ERC1967Proxy(address(impl), initData));
    }

    function run() external {
        address owner = vm.envAddress("OWNER");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        require(owner != address(0), "Deploy: OWNER must be set");
        require(deployer != address(0), "Deploy: DEPLOYER_ADDRESS must be set");
        require(owner != deployer, "Deploy: OWNER must differ from DEPLOYER_ADDRESS");

        console.log("Deployer (one-shot, retired after this tx):", deployer);
        console.log("Owner (operator, post-deploy admin):       ", owner);

        vm.startBroadcast();
        (Groth16Verifier verifier, Rewards rewards, GuessGame impl, address proxy) = deploy(owner);
        vm.stopBroadcast();

        console.log("GuessVerifier deployed at:                 ", address(verifier));
        console.log("Rewards deployed at:                       ", address(rewards));
        console.log("GuessGame implementation deployed at:      ", address(impl));
        console.log("GuessGame proxy deployed at:               ", proxy);
        console.log("Treasury (= Rewards) on proxy:             ", address(rewards));
    }
}
