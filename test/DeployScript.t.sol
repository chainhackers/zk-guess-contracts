// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {DeployScript} from "../script/Deploy.s.sol";
import {GuessGame} from "../src/GuessGame.sol";
import {Rewards} from "../src/Rewards.sol";

/// @notice Locks in the Phase B "deployer never owns the contract" rule. The script must
///         take the owner address as a parameter and refuse to broadcast when OWNER equals
///         the deployer EOA — that's the operational invariant that breaks the v1 monolithic
///         deployer/owner/funder graph.
contract DeployScriptTest is Test {
    DeployScript script;

    function setUp() public {
        script = new DeployScript();
    }

    /// @notice Direct call to the parameterized deploy helper: the resulting Rewards contract
    ///         must be owned by the OWNER address, never by msg.sender / the deployer.
    function test_deploy_setsOwnerOnRewards() public {
        address owner = makeAddr("operator");
        (, Rewards rewards,,) = script.deploy(owner);
        assertEq(rewards.owner(), owner, "Rewards.owner must be the configured operator");
    }

    /// @notice The GuessGame proxy must be initialized with OWNER as `_owner`, not the deployer.
    function test_deploy_setsOwnerOnGuessGameProxy() public {
        address owner = makeAddr("operator");
        (,,, address proxy) = script.deploy(owner);
        assertEq(GuessGame(proxy).owner(), owner, "GuessGame proxy owner must be the configured operator");
    }

    /// @notice Treasury must be the freshly-deployed Rewards contract — the new init reverts
    ///         on EOA treasury via the code-length check, so this is also a deploy smoke test.
    function test_deploy_treasuryIsRewardsContract() public {
        address owner = makeAddr("operator");
        (, Rewards rewards,, address proxy) = script.deploy(owner);
        assertEq(GuessGame(proxy).treasury(), address(rewards), "treasury must be the freshly-deployed Rewards");
    }

    /// @notice run() must refuse when OWNER == DEPLOYER_ADDRESS — preserves the three-role
    ///         separation in code, not just in operational discipline. This is the load-bearing
    ///         check; the `owner != 0` / `deployer != 0` requires inside `run()` are
    ///         defense-in-depth on top of Foundry's own envAddress parsing and aren't tested
    ///         here because process-level env state pollutes between Foundry tests.
    function test_run_revertsWhen_ownerEqualsDeployer() public {
        address shared = makeAddr("monolithic");
        vm.setEnv("OWNER", vm.toString(shared));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(shared));
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Deploy: OWNER must differ from DEPLOYER_ADDRESS"));
        script.run();
    }
}
