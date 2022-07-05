// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/LlamaPayV2Factory.sol";
import "./mock/LlamaToken.sol";

contract LlamaPayV2PayerNoYieldTest is Test {
    LlamaPayV2Factory public factory;
    LlamaPayV2PayerNoYield public payerContract;
    LlamaToken public llama;
    address public alice = address(1);
    address public bob = address(2);
    address public random = address(3);

    function setUp() public {
        factory = new LlamaPayV2Factory();
        llama = new LlamaToken();
        payerContract = factory.createLlamaPayContract(alice);
        llama.mint(alice, 10000e18);
        llama.mint(bob, 10000e18);
        vm.prank(alice);
        llama.approve(address(payerContract), 1000e18);
        vm.prank(alice);
        payerContract.deposit(address(llama), 1000e18);
    }

    function testDeposit() public {
        vm.prank(alice);
        llama.approve(address(payerContract), 1000e18);
        vm.prank(alice);
        payerContract.deposit(address(llama), 1000e18);
    }

    function testWithdrawPayer() public {
        vm.prank(alice);
        payerContract.withdrawPayer(address(llama), 1000e20);
    }

    function testWithdraw() public {
        vm.prank(alice);
        payerContract.createStream(address(llama), bob, 1e20);
        payerContract.withdraw(1, 0);
    }

    function testCreateStream() public {
        vm.prank(alice);
        payerContract.createStream(address(llama), bob, 1e20);
    }

    function testCancelStream() public {
        vm.prank(alice);
        payerContract.createStream(address(llama), bob, 1e20);
        vm.prank(alice);
        payerContract.cancelStream(1);
    }

    function testModifyStream() public {
        vm.prank(alice);
        payerContract.createStream(address(llama), bob, 1e20);
        vm.prank(alice);
        payerContract.modifyStream(1, address(llama), bob, 2e20);        
    }

    function testPauseStream() public {
        vm.prank(alice);
        payerContract.createStream(address(llama), bob, 1e20);
        vm.prank(alice);
        payerContract.pauseStream(1);
    }

    function testResumeStream() public {
        vm.prank(alice);
        payerContract.createStream(address(llama), bob, 1e20);
        vm.prank(alice);
        payerContract.pauseStream(1);
        vm.prank(alice);
        payerContract.resumeStream(1);
    }
}