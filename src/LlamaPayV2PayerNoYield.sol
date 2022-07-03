//SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

interface Factory {
    function mint(address _recipient) external returns (uint id);
    function burn(uint id) external returns (bool);
}

/// @title LlamaPay V2 Payer Contract
/// @author nemusona
contract LlamaPayV2PayerNoYield {

    using SafeTransferLib for ERC20;

    struct Stream {
        uint216 amountPerSec;
        uint40 lastUpdate;
    }

    struct Token {
        uint balance;
        uint216 totalPaidPerSec;
        uint40 lastUpdate;
    }

    address immutable public factory;
    address public owner;
    address public futureOwner;

    mapping(address => Token) tokens;
    mapping(uint => Stream) streams;
    mapping(uint => address) streamedToken;

    constructor(address _payer) {
        factory = msg.sender;
        owner = _payer;
    }

    function _updateToken(address _token) private {
        uint delta = block.timestamp - tokens[_token].lastUpdate;
        uint totalPayment = delta * tokens[_token].totalPaidPerSec;
        if (tokens[_token].balance >= totalPayment) {
            tokens[_token].balance -= totalPayment;
            tokens[_token].lastUpdate = uint40(block.timestamp);
        } else {
            uint timePaid = tokens[_token].balance / tokens[_token].totalPaidPerSec;
            tokens[_token].balance = tokens[_token].balance % tokens[_token].totalPaidPerSec;
            tokens[_token].lastUpdate += uint40(timePaid);
        }
    }

    function deposit(address _token, uint _amount) external {
        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint8 decimals = ERC20(_token).decimals();
        tokens[_token].balance += _amount * (10 ** (20 - decimals));
    }

    function withdrawPayer(address _token, uint _amount) external {
        require(msg.sender == owner, "not owner");

        _updateToken(_token);
        tokens[_token].balance -= _amount;
        require(block.timestamp == tokens[_token].lastUpdate, "already stream > available");
        uint8 decimals = ERC20(_token).decimals();
        ERC20(_token).safeTransfer(owner, _amount / (10 ** (20 - decimals)));
    }

    function withdraw(uint _id, uint _amount) external {
        require(streams[_id].lastUpdate != 0, "stream paused/cancelled");
        address payee = ERC721(factory).ownerOf(_id);
        require(payee != address(0), "stream nft burned");

        _updateToken(streamedToken[_id]);

        uint delta = tokens[streamedToken[_id]].lastUpdate - streams[_id].lastUpdate;
        uint available = delta * streams[_id].amountPerSec;

        require(available >= _amount, "amount > available");

        uint timePaid = _amount / streams[_id].amountPerSec;
        streams[_id].lastUpdate += uint40(timePaid);
        uint8 decimals = ERC20(streamedToken[_id]).decimals();
        uint toWithdraw = _amount / (10 ** (20 - decimals));
        ERC20(streamedToken[_id]).safeTransfer(payee, toWithdraw);
    }

    function createStream(address _token, address _payee, uint216 _amountPerSec) external {
        require(msg.sender == owner, "not owner");
        require(_payee != address(0), "payee == 0");
        require(_token != address(0), "token == 0");
        require(_amountPerSec > 0, "amtpersec <= 0");

        _updateToken(_token);

        require(tokens[_token].lastUpdate == block.timestamp, "in debt");
        tokens[_token].totalPaidPerSec += _amountPerSec;

        uint id = Factory(factory).mint(_payee);
        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            lastUpdate: uint40(block.timestamp)
        });
        streamedToken[id] = _token;
    }

    function cancelStream(uint _id) external {
        address payee = ERC721(factory).ownerOf(_id);
        require(streams[_id].lastUpdate != 0, "stream paused or cancelled");
        require(payee != address(0), "stream burned");

        _updateToken(streamedToken[_id]);

        uint canWithdraw = withdrawable(_id);
        bool burned = Factory(factory).burn(_id);
        require(burned, "stream cannot be burned");
        streams[_id].lastUpdate = 0;
        tokens[streamedToken[_id]].totalPaidPerSec -= streams[_id].amountPerSec;
        ERC20(streamedToken[_id]).safeTransfer(payee, canWithdraw);
    }

    function modifyStream(uint _id, address _newToken, address _newPayee, uint216 _newAmountPerSec) external {
        address payee = ERC721(factory).ownerOf(_id);
        require(msg.sender == owner, "not owner");
        require(payee != address(0), "stream burned");
        require(_newToken != address(0), "token == 0");
        require(_newPayee != address(0), "payee == 0");
        require(_newAmountPerSec > 0, "amtPerSec <= 0");

        _updateToken(streamedToken[_id]);
        uint canWithdraw = withdrawable(_id);
        ERC20(streamedToken[_id]).safeTransfer(payee, canWithdraw);
        tokens[streamedToken[_id]].totalPaidPerSec -= streams[_id].amountPerSec;

        _updateToken(_newToken);
        require(tokens[_newToken].lastUpdate == block.timestamp, "in debt");
        tokens[_newToken].totalPaidPerSec += _newAmountPerSec;
        streamedToken[_id] = _newToken;

        streams[_id] = Stream({
            amountPerSec: _newAmountPerSec,
            lastUpdate: uint40(block.timestamp)
        });

        if(_newPayee != payee) {
            ERC721(factory).safeTransferFrom(payee, _newPayee, _id);
        }

    }

    function pauseStream(uint _id) external {
        address payee = ERC721(factory).ownerOf(_id);
        require(msg.sender == owner, "not owner");
        require(payee != address(0), "stream burned");
        require(streams[_id].lastUpdate != 0, "already paused/cancelled");

        _updateToken(streamedToken[_id]);

        uint canWithdraw = withdrawable(_id);
        streams[_id].lastUpdate = 0;
        tokens[streamedToken[_id]].totalPaidPerSec -= streams[_id].amountPerSec;
        ERC20(streamedToken[_id]).safeTransfer(payee, canWithdraw);
    }

    function resumeStream(uint _id) external {
        require(msg.sender == owner, "not owner");
        require(ERC721(factory).ownerOf(_id) != address(0), "stream burned");
        require(streams[_id].lastUpdate == 0, "stream is not paused");

        _updateToken(streamedToken[_id]);
        require(tokens[streamedToken[_id]].lastUpdate == block.timestamp, "in debt");
        streams[_id].lastUpdate = uint40(block.timestamp);
        tokens[streamedToken[_id]].totalPaidPerSec += streams[_id].amountPerSec;
    }

    function transferOwnership(address _futureOwner) external {
    require(msg.sender == owner, "not owner");
        futureOwner = _futureOwner;
    }

    function applyTransferOwnership() external {
        require(msg.sender == futureOwner, "not future owner");
        owner = msg.sender;
    }

    function withdrawable(uint _id) public view returns (uint canWithdraw) {
        uint delta = block.timestamp - tokens[streamedToken[_id]].lastUpdate;
        uint totalPayment = delta * tokens[streamedToken[_id]].totalPaidPerSec;

        uint lastPayerUpdate;
        if (tokens[streamedToken[_id]].balance >= totalPayment) {
            lastPayerUpdate = block.timestamp;
        } else {
            uint timePaid = tokens[streamedToken[_id]].balance / tokens[streamedToken[_id]].totalPaidPerSec;
            lastPayerUpdate = tokens[streamedToken[_id]].lastUpdate + timePaid; 
        }

        uint payeeDelta = lastPayerUpdate - streams[_id].lastUpdate;
        uint decimals = ERC20(streamedToken[_id]).decimals();
        canWithdraw = (payeeDelta * streams[_id].amountPerSec) / (10 ** (20 - decimals));
    }



}