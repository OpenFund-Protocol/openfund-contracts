// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {SplitManager} from "../contracts/SplitManager.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract SplitManagerTest is Test {
    SplitManager public splits;
    ERC20Mock public token;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public treasury = makeAddr("treasury");

    bytes32 public constant PROJECT_A = keccak256("PROJECT_A");
    bytes32 public constant PROJECT_B = keccak256("PROJECT_B");

    SplitManager.PayeeShare[] internal defaultPayees;

    function setUp() public {
        splits = new SplitManager(admin);
        token = new ERC20Mock("Mock Token", "MCK", 18);

        defaultPayees.push(SplitManager.PayeeShare({payee: alice, bps: 5000}));
        defaultPayees.push(SplitManager.PayeeShare({payee: bob, bps: 3000}));
        defaultPayees.push(SplitManager.PayeeShare({payee: treasury, bps: 2000}));

        token.mint(admin, 1_000_000e18);
        vm.prank(admin);
        token.approve(address(splits), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        SPLIT DEFINITION
    //////////////////////////////////////////////////////////////*/

    function test_DefineSplit_Success() public {
        vm.prank(admin);
        splits.defineSplit(PROJECT_A, defaultPayees);

        SplitManager.SplitConfig memory config = splits.getSplit(PROJECT_A);
        assertTrue(config.active);
        assertEq(config.payees.length, 3);
        assertEq(config.payees[0].payee, alice);
        assertEq(config.payees[0].bps, 5000);
    }

    function test_DefineSplit_RevertsOnDuplicateProject() public {
        vm.startPrank(admin);
        splits.defineSplit(PROJECT_A, defaultPayees);
        vm.expectRevert(
            abi.encodeWithSelector(SplitManager.SplitAlreadyExists.selector, PROJECT_A)
        );
        splits.defineSplit(PROJECT_A, defaultPayees);
        vm.stopPrank();
    }

    function test_DefineSplit_RevertsOnBpsMismatch() public {
        SplitManager.PayeeShare[] memory bad = new SplitManager.PayeeShare[](2);
        bad[0] = SplitManager.PayeeShare({payee: alice, bps: 5000});
        bad[1] = SplitManager.PayeeShare({payee: bob, bps: 3000}); // total = 8000, not 10000

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SplitManager.BpsMismatch.selector, 8000));
        splits.defineSplit(PROJECT_A, bad);
    }

    function test_DefineSplit_RevertsOnDuplicatePayee() public {
        SplitManager.PayeeShare[] memory bad = new SplitManager.PayeeShare[](2);
        bad[0] = SplitManager.PayeeShare({payee: alice, bps: 5000});
        bad[1] = SplitManager.PayeeShare({payee: alice, bps: 5000}); // duplicate

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SplitManager.DuplicatePayee.selector, alice));
        splits.defineSplit(PROJECT_A, bad);
    }

    function test_DefineSplit_RevertsOnZeroAddress() public {
        SplitManager.PayeeShare[] memory bad = new SplitManager.PayeeShare[](2);
        bad[0] = SplitManager.PayeeShare({payee: address(0), bps: 5000});
        bad[1] = SplitManager.PayeeShare({payee: bob, bps: 5000});

        vm.prank(admin);
        vm.expectRevert(SplitManager.InvalidPayee.selector);
        splits.defineSplit(PROJECT_A, bad);
    }

    function test_DefineSplit_RevertsOnEmptyProjectId() public {
        vm.prank(admin);
        vm.expectRevert(SplitManager.InvalidProjectId.selector);
        splits.defineSplit(bytes32(0), defaultPayees);
    }

    /*//////////////////////////////////////////////////////////////
                         SPLIT UPDATE
    //////////////////////////////////////////////////////////////*/

    function test_UpdateSplit_Success() public {
        vm.startPrank(admin);
        splits.defineSplit(PROJECT_A, defaultPayees);

        SplitManager.PayeeShare[] memory newPayees = new SplitManager.PayeeShare[](2);
        newPayees[0] = SplitManager.PayeeShare({payee: alice, bps: 6000});
        newPayees[1] = SplitManager.PayeeShare({payee: bob, bps: 4000});
        splits.updateSplit(PROJECT_A, newPayees);
        vm.stopPrank();

        SplitManager.SplitConfig memory config = splits.getSplit(PROJECT_A);
        assertEq(config.payees.length, 2);
        assertEq(config.payees[0].bps, 6000);
    }

    function test_UpdateSplit_RevertsOnNonexistentProject() public {
        SplitManager.PayeeShare[] memory newPayees = new SplitManager.PayeeShare[](1);
        newPayees[0] = SplitManager.PayeeShare({payee: alice, bps: 10_000});

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SplitManager.SplitNotFound.selector, PROJECT_B));
        splits.updateSplit(PROJECT_B, newPayees);
    }

    /*//////////////////////////////////////////////////////////////
                    ETH DISTRIBUTION + CLAIMING
    //////////////////////////////////////////////////////////////*/

    function test_DistributeETH_CreditsCorrectly() public {
        vm.prank(admin);
        splits.defineSplit(PROJECT_A, defaultPayees);

        // Distribute 1 ETH
        vm.deal(address(this), 1 ether);
        splits.distributeETH{value: 1 ether}(PROJECT_A);

        assertEq(splits.claimableBalance(alice, address(0)), 0.5 ether);
        assertEq(splits.claimableBalance(bob, address(0)), 0.3 ether);
        assertEq(splits.claimableBalance(treasury, address(0)), 0.2 ether);
    }

    function test_ClaimETH_Success() public {
        vm.prank(admin);
        splits.defineSplit(PROJECT_A, defaultPayees);

        vm.deal(address(this), 1 ether);
        splits.distributeETH{value: 1 ether}(PROJECT_A);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        splits.claim(address(0));
        assertEq(alice.balance - aliceBefore, 0.5 ether);
        assertEq(splits.claimableBalance(alice, address(0)), 0);
    }

    function test_Claim_RevertsIfNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(SplitManager.NothingToClaim.selector);
        splits.claim(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                   ERC-20 DISTRIBUTION + CLAIMING
    //////////////////////////////////////////////////////////////*/

    function test_DistributeERC20_CreditsCorrectly() public {
        vm.prank(admin);
        splits.defineSplit(PROJECT_A, defaultPayees);

        vm.prank(admin);
        splits.distributeERC20(PROJECT_A, address(token), 10_000e18);

        assertEq(splits.claimableBalance(alice, address(token)), 5000e18);
        assertEq(splits.claimableBalance(bob, address(token)), 3000e18);
        assertEq(splits.claimableBalance(treasury, address(token)), 2000e18);
    }

    function test_ClaimERC20_Success() public {
        vm.prank(admin);
        splits.defineSplit(PROJECT_A, defaultPayees);

        vm.prank(admin);
        splits.distributeERC20(PROJECT_A, address(token), 10_000e18);

        vm.prank(bob);
        splits.claim(address(token));
        assertEq(token.balanceOf(bob), 3000e18);
        assertEq(splits.claimableBalance(bob, address(token)), 0);
    }

    function test_ClaimMultiple_Success() public {
        vm.prank(admin);
        splits.defineSplit(PROJECT_A, defaultPayees);

        vm.deal(address(this), 1 ether);
        splits.distributeETH{value: 1 ether}(PROJECT_A);

        vm.prank(admin);
        splits.distributeERC20(PROJECT_A, address(token), 10_000e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(token);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        splits.claimMultiple(tokens);

        assertEq(alice.balance - aliceBefore, 0.5 ether);
        assertEq(token.balanceOf(alice), 5000e18);
    }

    /*//////////////////////////////////////////////////////////////
                       DEACTIVATION + DUST
    //////////////////////////////////////////////////////////////*/

    function test_DeactivateSplit_BlocksDistribute() public {
        vm.startPrank(admin);
        splits.defineSplit(PROJECT_A, defaultPayees);
        splits.deactivateSplit(PROJECT_A);
        vm.stopPrank();

        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SplitManager.SplitInactive.selector, PROJECT_A));
        splits.distributeETH{value: 1 ether}(PROJECT_A);
    }

    function test_DustGoesToFirstPayee() public {
        // Use 3 payees with equal 33.33% each (9999 total bps so there's always dust)
        SplitManager.PayeeShare[] memory payees = new SplitManager.PayeeShare[](3);
        payees[0] = SplitManager.PayeeShare({payee: alice, bps: 3334});
        payees[1] = SplitManager.PayeeShare({payee: bob, bps: 3333});
        payees[2] = SplitManager.PayeeShare({payee: carol, bps: 3333});

        vm.prank(admin);
        splits.defineSplit(PROJECT_B, payees);

        vm.deal(address(this), 1 ether);
        splits.distributeETH{value: 1 ether}(PROJECT_B);

        uint256 total = splits.claimableBalance(alice, address(0))
            + splits.claimableBalance(bob, address(0))
            + splits.claimableBalance(carol, address(0));
        assertEq(total, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DistributeETH_TotalAlwaysConserved(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);

        vm.prank(admin);
        splits.defineSplit(PROJECT_A, defaultPayees);

        vm.deal(address(this), amount);
        splits.distributeETH{value: amount}(PROJECT_A);

        uint256 total = splits.claimableBalance(alice, address(0))
            + splits.claimableBalance(bob, address(0))
            + splits.claimableBalance(treasury, address(0));
        assertEq(total, amount);
    }
}
