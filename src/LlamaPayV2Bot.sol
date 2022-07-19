//SPDX-License-Identifier: AGPL-3.0-only

import "./BoringBatchable.sol";

pragma solidity ^0.8.0;

interface Payer {
    function owner() external view returns (address);
    function createStream(address _vault, address _payee, uint216 _amountPerSec) external;
    function cancelStream(uint _id) external;
    function withdraw(uint _id, uint _amount) external;
    function getWithdrawable(uint _id) external view returns (uint withdrawable);
}

// NEED TO HANDLE: Reverts, Payer Balances, Cancelled Streams, Stuck Txs

contract LlamaPayV2Bot is BoringBatchable {

    address public bot;
    address public llama = address(0);

    event CreateStreamScheduled(address indexed payer, address indexed vault, address indexed payee, uint216 amountPerSec, uint40 execution);
    event CancelStreamScheduled(address indexed payer, uint id, uint40 execution);
    event AutoWithdrawScheduled(address indexed payer, uint id, uint40 frequency);
    event AutoWithdrawCancelled(address indexed payer, uint id);
    event CreateStreamExecuted(address indexed payer, address indexed vault, address indexed payee, uint216 amountPerSec);
    event CancelStreamExecuted(address indexed payer, uint id);
    event WithdrawExecuted(address indexed payer, uint id);
    

    constructor(address _bot) {
        bot = _bot;
    }

    mapping(address => uint) public balances;

    function scheduleCreateStream(address _payer, address _vault, address _payee, uint216 _amountPerSec, uint40 _execution) external{
        require(msg.sender == Payer(_payer).owner(), "not owner");
        emit CreateStreamScheduled(_payer, _vault, _payee, _amountPerSec, _execution);
    }

    function scheduleCancelStream(address _payer, uint _id, uint40 _execution) external {
        require(msg.sender == Payer(_payer).owner(), "not owner");
        emit CancelStreamScheduled(_payer, _id, _execution);
    }

    function scheduleAutoWithdrawal(address _payer, uint _id, uint40 _frequency) external {
        require(msg.sender == Payer(_payer).owner(), "not owner");
        emit AutoWithdrawScheduled(_payer, _id, _frequency);
    }

    function cancelAutoWithdrawal(address _payer, uint _id) external {
        require(msg.sender == Payer(_payer).owner(), "not owner");
        emit AutoWithdrawCancelled(_payer, _id);
    }

    function executeCreateStream(address _payer, address _vault, address _payee, uint216 _amountPerSec) external {
        require(msg.sender == bot, "not bot");
        Payer(_payer).createStream(_vault, _payee, _amountPerSec);
        emit CreateStreamExecuted(_payer, _vault, _payee, _amountPerSec);
    }

    function executeCancelStream(address _payer, uint _id) external {
        require(msg.sender == bot, "not bot");
        Payer(_payer).cancelStream(_id);
        emit CancelStreamExecuted(_payer, _id);
    }

    function executeWithdraw(address _payer, uint _id) external {
        require(msg.sender == bot, "not bot");
        uint withdrawable = Payer(_payer).getWithdrawable(_id);
        Payer(_payer).withdraw(_id, withdrawable);
        emit WithdrawExecuted(_payer, _id);
    }

    function deposit(address _payer) external payable {
        require(msg.value > 0, "need to send ether");
        (bool sent,) = bot.call{value: msg.value}("");
        require(sent, "failed to send ether to bot");
        balances[_payer] += msg.value;
    }

    function changeBot(address _newBot) external {
        require(msg.sender == llama, "not llama");
        bot = _newBot;
    }

}