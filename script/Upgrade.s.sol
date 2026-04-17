// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../src/GuessGame.sol";

contract UpgradeScript is Script {
    function run() external {
        // Proxy address from environment (required)
        address proxy = vm.envAddress("PROXY_ADDRESS");
        console.log("Upgrading proxy at:", proxy);

        vm.startBroadcast();

        // Deploy new implementation
        GuessGame newImpl = new GuessGame();
        console.log("New implementation deployed at:", address(newImpl));

        // Upgrade proxy to new implementation (no initialization data needed)
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), "");
        console.log("Proxy upgraded successfully");

        vm.stopBroadcast();
    }
}
