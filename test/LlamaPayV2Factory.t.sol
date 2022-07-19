// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/LlamaPayV2Factory.sol";
import "../src/LlamaPayV2Payer.sol";
import "./mock/LlamaToken.sol";

contract LlamaPayV2FactoryTest is Test {

    LlamaPayV2Factory public llamaPayFactory;
    LlamaToken public llamaToken;
    address public immutable alice = address(1);
    address public immutable bob = address(2);
    address public immutable vault = address(3);
    
    function setUp() public {
        llamaPayFactory = new LlamaPayV2Factory();
        llamaToken = new LlamaToken();
        llamaToken.mint(alice, 10000e18);
        llamaToken.mint(bob, 10000e18);
    }

    function testCreateLlamaPayPayer() public {
        vm.prank(alice);
        llamaPayFactory.createLlamaPayContract();
    }

    function testMintIsRestricted() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not payer contract"));
        llamaPayFactory.mint(alice);
    }

    function testBurnIsRestricted() public {
        vm.prank(alice);
        LlamaPayV2Payer payer = llamaPayFactory.createLlamaPayContract();
        vm.prank(alice);
        payer.createStream(vault, bob, 10000);
        vm.prank(alice);
        vm.expectRevert(bytes("not payer contract"));
        llamaPayFactory.burn(0);
    }

    function testTransferLlamaPayContractIsRestricted() public {
        vm.prank(alice);
        llamaPayFactory.createLlamaPayContract();
        vm.prank(alice);
        vm.expectRevert(bytes("not payer contract"));
        llamaPayFactory.transferLlamaPayContract(alice, bob);
    }

    function testCannotCreateMultipleLlamaPayContracts() public {
        vm.prank(alice);
        llamaPayFactory.createLlamaPayContract();
        vm.prank(alice);
        vm.expectRevert(bytes("contract already exists"));
        llamaPayFactory.createLlamaPayContract();
    }

}

