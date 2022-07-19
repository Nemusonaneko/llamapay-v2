// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/LlamaPayV2Factory.sol";
import "../src/LlamaPayV2Payer.sol";
import "./mock/LlamaToken.sol";
import "./mock/LlamaVault.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";


contract LlamaPayV2PayerTest is Test {

    LlamaPayV2Factory public llamaPayFactory;
    LlamaPayV2Payer public llamaPayPayer;
    LlamaToken public llamaToken;
    LlamaVault public llamaVault;

    address public immutable alice = address(1);
    address public immutable bob = address(2);

    function setUp() public {
        llamaPayFactory = new LlamaPayV2Factory();
        llamaToken = new LlamaToken();
        llamaToken.mint(alice, 10000e18);
        vm.prank(alice);
        llamaPayPayer = llamaPayFactory.createLlamaPayContract();
        llamaVault = new LlamaVault(ERC20(llamaToken));
        vm.prank(alice);
        llamaToken.approve(address(llamaPayPayer), 1000e18);
        vm.prank(alice);
        llamaPayPayer.deposit(address(llamaToken), address(llamaVault), 1000e18);
        vm.warp(100 seconds);
    }

    function testDeposit() public {
        vm.prank(alice);
        llamaToken.approve(address(llamaPayPayer), 1000e18);
        vm.prank(alice);
        llamaPayPayer.deposit(address(llamaToken), address(llamaVault), 1000e18);
        (uint balance,,,) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(llamaVault.balanceOf(address(llamaPayPayer)), 2000e18);
        assertEq(balance, 2000e20);
    }

    function testWithdrawPayer() public {
        vm.prank(alice);
        llamaToken.approve(address(llamaPayPayer), 1000e18);
        vm.prank(alice);
        llamaPayPayer.deposit(address(llamaToken), address(llamaVault), 1000e18);
        (uint balance,,,) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(llamaVault.balanceOf(address(llamaPayPayer)), 2000e18);
        assertEq(balance, 2000e20);

        vm.prank(alice);
        llamaPayPayer.withdrawPayer(address(llamaVault), 1000e20);
        (balance,,,) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(llamaVault.balanceOf(address(llamaPayPayer)), 1000e18);
        assertEq(balance, 1000e20);
    }

    function testCreateStream() public {
        vm.prank(alice);
        llamaPayPayer.createStream(address(llamaVault), bob, 1e20);
        (,,,uint216 totalPaidPerSec) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(totalPaidPerSec, 1e20);
    }

    function testCancelStream() public {
        vm.prank(alice);
        llamaPayPayer.createStream(address(llamaVault), bob, 1e20);
        (,,,uint216 totalPaidPerSec) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(totalPaidPerSec, 1e20);
        vm.prank(alice);
        llamaPayPayer.cancelStream(0);
        (,,,totalPaidPerSec) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(totalPaidPerSec, 0);
        
    }

    function testPauseStream() public {
        vm.prank(alice);
        llamaPayPayer.createStream(address(llamaVault), bob, 1e20);
        (,,,uint216 totalPaidPerSec) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(totalPaidPerSec, 1e20);
        vm.prank(alice);
        llamaPayPayer.pauseStream(0);
        (,,,totalPaidPerSec) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(totalPaidPerSec, 0);
    }

    function testResumeStream() public {
        vm.prank(alice);
        llamaPayPayer.createStream(address(llamaVault), bob, 1e20);
        (,,,uint216 totalPaidPerSec) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(totalPaidPerSec, 1e20);
        vm.prank(alice);
        llamaPayPayer.pauseStream(0);
        (,,,totalPaidPerSec) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(totalPaidPerSec, 0);
        vm.prank(alice);
        llamaPayPayer.resumeStream(0);
        (,,,totalPaidPerSec) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(totalPaidPerSec, 1e20);
    }

    function testTransferOwnership() public {
        vm.prank(alice);
        llamaPayPayer.transferOwnership(bob);
        assertEq(llamaPayPayer.futureOwner(), bob);
    }

    function testApplyTransferOwnership() public {
        vm.prank(alice);
        llamaPayPayer.transferOwnership(bob);
        assertEq(llamaPayPayer.futureOwner(), bob);
        vm.prank(bob);
        llamaPayPayer.applyTransferOwnership();
        assertEq(llamaPayPayer.owner(), bob);
    }

    function testWithdraw() public {
        vm.prank(alice);
        llamaPayPayer.createStream(address(llamaVault), bob, 1e20);
        vm.warp(1 days);
        llamaPayPayer.withdraw(0, 1000e20);
        assertEq(llamaToken.balanceOf(bob), 1000e18);
        (uint balance,,,) = llamaPayPayer.vaults(address(llamaVault));
        assertEq(balance, 0);
        assertEq(llamaVault.totalAssets(), 0);
    }

    function testModifyStream() public {
        vm.prank(alice);
        llamaPayPayer.createStream(address(llamaVault), bob, 1e20);
        vm.prank(alice);
        llamaPayPayer.modifyStream(0, 2e20);
    }

}