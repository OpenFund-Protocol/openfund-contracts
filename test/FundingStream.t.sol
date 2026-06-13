// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {FundingStream} from "../contracts/FundingStream.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract FundingStreamTest is Test {
    FundingStream public funding;
    ERC20Mock public token;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint48 public startTime;
    uint48 public endTime;

    function setUp() public {
        funding = new FundingStream(admin);
        token = new ERC20Mock("Test Token", "TST", 18);

        // default stream window: starts in 1 hour, runs 30 days
        startTime = uint48(block.timestamp + 1 hours);
        endTime = uint48(block.timestamp + 31 days);

        // fund alice
        vm.deal(alice, 100 ether);
        token.mint(alice, 1_000_000e18);
        vm.prank(alice);
        token.approve(address(funding), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        ETH STREAM CREATION
    //////////////////////////////////////////////////////////////*/

    function test_CreateETHStream_Success() public {
        vm.prank(alice);
        uint256 streamId = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        FundingStream.Stream memory s = funding.getStream(streamId);
        assertEq(s.sender, alice);
        assertEq(s.recipient, bob);
        assertEq(s.token, address(0));
        assertEq(s.totalDeposited, 1 ether);
        assertEq(s.withdrawn, 0);
        assertEq(s.cliffDuration, 0);
        assertEq(uint8(s.status), uint8(FundingStream.StreamStatus.Active));
    }

    function test_CreateETHStream_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit FundingStream.StreamCreated(0, alice, bob, address(0), 1 ether, startTime, endTime);

        vm.prank(alice);
        funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);
    }

    function test_CreateETHStream_RevertsOnZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(FundingStream.InvalidAmount.selector);
        funding.createETHStream{value: 0}(bob, startTime, endTime, 0);
    }

    function test_CreateETHStream_RevertsOnSelfRecipient() public {
        vm.prank(alice);
        vm.expectRevert(FundingStream.InvalidRecipient.selector);
        funding.createETHStream{value: 1 ether}(alice, startTime, endTime, 0);
    }

    function test_CreateETHStream_RevertsOnStartInPast() public {
        vm.prank(alice);
        vm.expectRevert(FundingStream.StartTimeInPast.selector);
        funding.createETHStream{value: 1 ether}(bob, uint48(block.timestamp - 1), endTime, 0);
    }

    function test_CreateETHStream_RevertsOnShortDuration() public {
        vm.prank(alice);
        vm.expectRevert(FundingStream.InvalidDuration.selector);
        funding.createETHStream{value: 1 ether}(bob, startTime, startTime + 30 minutes, 0);
    }

    function test_CreateETHStream_RevertsOnCliffEqualsDuration() public {
        uint48 duration = endTime - startTime;
        vm.prank(alice);
        vm.expectRevert(FundingStream.InvalidCliffDuration.selector);
        funding.createETHStream{value: 1 ether}(bob, startTime, endTime, duration);
    }

    /*//////////////////////////////////////////////////////////////
                       ERC20 STREAM CREATION
    //////////////////////////////////////////////////////////////*/

    function test_CreateERC20Stream_Success() public {
        vm.prank(alice);
        uint256 streamId =
            funding.createERC20Stream(bob, address(token), 1000e18, startTime, endTime, 0);

        FundingStream.Stream memory s = funding.getStream(streamId);
        assertEq(s.token, address(token));
        assertEq(s.totalDeposited, 1000e18);
        assertEq(token.balanceOf(address(funding)), 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                            VESTING MATH
    //////////////////////////////////////////////////////////////*/

    function test_VestedAmount_BeforeStart() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);
        assertEq(funding.vestedAmount(id), 0);
    }

    function test_VestedAmount_AtMidpoint() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        // warp to midpoint
        vm.warp(startTime + (endTime - startTime) / 2);
        uint256 vested = funding.vestedAmount(id);
        // should be roughly 50% (allow 1 wei rounding)
        assertApproxEqAbs(vested, 0.5 ether, 1);
    }

    function test_VestedAmount_AfterEnd() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);
        vm.warp(endTime + 1);
        assertEq(funding.vestedAmount(id), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          CLIFF VESTING
    //////////////////////////////////////////////////////////////*/

    function test_Cliff_NothingVestedBeforeCliff() public {
        // 7-day cliff on a 30-day stream
        uint48 cliff = 7 days;
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, cliff);

        // Just before cliff elapses: nothing vested
        vm.warp(startTime + cliff - 1);
        assertEq(funding.vestedAmount(id), 0);

        vm.prank(bob);
        vm.expectRevert(FundingStream.NothingToWithdraw.selector);
        funding.withdraw(id);
    }

    function test_Cliff_VestingBeginsAtCliffBoundary() public {
        uint48 cliff = 7 days;
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, cliff);

        // Exactly at cliff end
        vm.warp(startTime + cliff);
        uint256 vested = funding.vestedAmount(id);
        uint256 expected = (1 ether * uint256(cliff)) / uint256(endTime - startTime);
        assertEq(vested, expected);
    }

    function test_Cliff_FullAmountAfterEnd() public {
        uint48 cliff = 7 days;
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, cliff);

        vm.warp(endTime + 1);
        assertEq(funding.vestedAmount(id), 1 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        funding.withdraw(id);
        assertEq(bob.balance - bobBefore, 1 ether);
    }

    function test_Cliff_ZeroCliffBehavesLikeLinear() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        // Right after start should have non-zero vesting
        vm.warp(startTime + 1 days);
        assertGt(funding.vestedAmount(id), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_Success() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        // warp to full vesting
        vm.warp(endTime + 1);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        funding.withdraw(id);

        assertEq(bob.balance - bobBefore, 1 ether);
        assertEq(funding.getStream(id).withdrawn, 1 ether);
        assertEq(uint8(funding.getStream(id).status), uint8(FundingStream.StreamStatus.Completed));
    }

    function test_Withdraw_PartialThenFull() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        // warp to 25%
        vm.warp(startTime + (endTime - startTime) / 4);
        vm.prank(bob);
        funding.withdraw(id);
        assertApproxEqAbs(funding.getStream(id).withdrawn, 0.25 ether, 1);

        // warp to end
        vm.warp(endTime + 1);
        vm.prank(bob);
        funding.withdraw(id);
        assertEq(funding.getStream(id).withdrawn, 1 ether);
    }

    function test_Withdraw_RevertsIfNotRecipient() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);
        vm.warp(endTime + 1);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FundingStream.NotStreamRecipient.selector, id));
        funding.withdraw(id);
    }

    function test_Withdraw_RevertsIfNothingVested() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        vm.prank(bob);
        vm.expectRevert(FundingStream.NothingToWithdraw.selector);
        funding.withdraw(id);
    }

    /*//////////////////////////////////////////////////////////////
                              TOP-UP
    //////////////////////////////////////////////////////////////*/

    function test_FundETHStream_IncreasesDeposit() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        vm.deal(carol, 1 ether);
        vm.prank(carol);
        funding.fundETHStream{value: 0.5 ether}(id);

        assertEq(funding.getStream(id).totalDeposited, 1.5 ether);
    }

    function test_FundETHStream_RevertsOnInactiveStream() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        // cancel the stream
        vm.prank(alice);
        funding.cancel(id);

        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FundingStream.StreamNotActive.selector, id));
        funding.fundETHStream{value: 0.5 ether}(id);
    }

    /*//////////////////////////////////////////////////////////////
                            CANCELLATION
    //////////////////////////////////////////////////////////////*/

    function test_Cancel_ReturnsCorrectAmounts() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        // warp to 50%
        vm.warp(startTime + (endTime - startTime) / 2);

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        funding.cancel(id);

        uint256 aliceGained = alice.balance - aliceBefore;
        uint256 bobGained = bob.balance - bobBefore;

        // Both should get ~50% (allow 1 wei rounding)
        assertApproxEqAbs(aliceGained, 0.5 ether, 1);
        assertApproxEqAbs(bobGained, 0.5 ether, 1);
        assertEq(uint8(funding.getStream(id).status), uint8(FundingStream.StreamStatus.Cancelled));
    }

    function test_Cancel_RevertsIfNotSender() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FundingStream.NotStreamSender.selector, id));
        funding.cancel(id);
    }

    /*//////////////////////////////////////////////////////////////
                           STREAM PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_PauseStream_BlocksWithdraw() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        vm.prank(admin);
        funding.pauseStream(id);

        assertEq(uint8(funding.getStream(id).status), uint8(FundingStream.StreamStatus.Paused));

        vm.warp(endTime + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FundingStream.StreamNotActive.selector, id));
        funding.withdraw(id);
    }

    function test_ResumeStream_Success() public {
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        vm.startPrank(admin);
        funding.pauseStream(id);
        funding.resumeStream(id);
        vm.stopPrank();

        assertEq(uint8(funding.getStream(id).status), uint8(FundingStream.StreamStatus.Active));
    }

    /*//////////////////////////////////////////////////////////////
                           STREAM INDEXES
    //////////////////////////////////////////////////////////////*/

    function test_GetRecipientStreams() public {
        vm.startPrank(alice);
        funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);
        funding.createETHStream{value: 0.5 ether}(bob, startTime, endTime, 0);
        vm.stopPrank();

        uint256[] memory ids = funding.getRecipientStreams(bob);
        assertEq(ids.length, 2);
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_VestedAmount_LinearInvariant(uint256 warpTime) public {
        warpTime = bound(warpTime, uint256(startTime), uint256(endTime));

        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, 0);

        vm.warp(warpTime);
        uint256 vested = funding.vestedAmount(id);
        // vested must be [0, totalDeposited]
        assertLe(vested, 1 ether);
        assertGe(vested, 0);
    }

    function testFuzz_VestedAmount_MonotonicallyNonDecreasing(uint256 t1, uint256 t2) public {
        uint48 cliff = 7 days;
        vm.prank(alice);
        uint256 id = funding.createETHStream{value: 1 ether}(bob, startTime, endTime, cliff);

        t1 = bound(t1, uint256(startTime), uint256(endTime));
        t2 = bound(t2, t1, uint256(endTime) + 1 days);

        vm.warp(t1);
        uint256 vested1 = funding.vestedAmount(id);

        vm.warp(t2);
        uint256 vested2 = funding.vestedAmount(id);

        assertGe(vested2, vested1);
    }
}
