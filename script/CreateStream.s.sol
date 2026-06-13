// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FundingStream} from "../contracts/FundingStream.sol";

/**
 * @title CreateStream
 * @notice Example script to create a 30-day ETH funding stream.
 *
 * Environment variables required:
 *   FUNDING_STREAM_ADDRESS  — deployed FundingStream contract
 *   RECIPIENT_ADDRESS       — stream recipient
 *   STREAM_AMOUNT_WEI       — amount in wei (default: 0.1 ETH)
 */
contract CreateStream is Script {
    function run() external {
        address streamContract = vm.envAddress("FUNDING_STREAM_ADDRESS");
        address recipient = vm.envAddress("RECIPIENT_ADDRESS");
        uint256 amount = vm.envOr("STREAM_AMOUNT_WEI", uint256(0.1 ether));

        FundingStream funding = FundingStream(payable(streamContract));

        uint48 startTime = uint48(block.timestamp + 5 minutes);
        uint48 endTime = uint48(block.timestamp + 30 days);

        vm.startBroadcast();
        uint256 streamId =
            funding.createETHStream{value: amount}(recipient, startTime, endTime, 0);
        vm.stopBroadcast();

        console2.log("Stream created - ID:", streamId);
        console2.log("Recipient:", recipient);
        console2.log("Amount (wei):", amount);
        console2.log("Start:", startTime);
        console2.log("End:", endTime);
    }
}
