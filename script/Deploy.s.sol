// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ContributorRegistry} from "../contracts/ContributorRegistry.sol";
import {FundingStream} from "../contracts/FundingStream.sol";
import {SplitManager} from "../contracts/SplitManager.sol";
import {MilestoneVault} from "../contracts/MilestoneVault.sol";

/**
 * @title Deploy
 * @notice Deploys the full OpenFund Protocol suite.
 *
 * Usage:
 *   # Local Anvil
 *   forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
 *
 *   # Testnet (e.g. Sepolia) — set ADMIN_ADDRESS in your .env
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract Deploy is Script {
    function run() external returns (
        ContributorRegistry registry,
        FundingStream funding,
        SplitManager splits,
        MilestoneVault milestoneVault
    ) {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        console2.log("Deploying OpenFund Protocol");
        console2.log("Admin:", admin);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast();

        registry = new ContributorRegistry(admin);
        console2.log("ContributorRegistry:", address(registry));

        funding = new FundingStream(admin);
        console2.log("FundingStream:", address(funding));

        splits = new SplitManager(admin);
        console2.log("SplitManager:", address(splits));

        milestoneVault = new MilestoneVault(admin);
        console2.log("MilestoneVault:", address(milestoneVault));

        vm.stopBroadcast();

        console2.log("\nDeployment complete.");
    }
}
