//SPDX-License-Identifier: None

pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";

interface Factory {
    function mint(address _recipient) external returns (uint id);
    function burn(uint id) external returns (bool);
}

contract LlamaPayV2Payer {
    
    struct Stream {
        uint216 amountPerSec;
        uint40 lastUpdate;
        address token;
        address vaultToken;
    }

    struct Token {
        uint balance;
        uint216 totalPaidPerSec;
        uint40 lastPayerUpdate;
    }

    mapping(address => Token) tokens;
    mapping(uint => Stream) streams;

    address immutable public factory;
    address public owner;
    address public futureOwner;

    constructor(address _payer) {
        factory = msg.sender;
        owner = _payer;
    }

    function deposit(address _token, uint _amount, address _vaultToken) external {
        ERC20 token = ERC20(_token);
        bool transferred = token.transferFrom(msg.sender, address(this), _amount);
        require(transferred, "failed to transfer tokens");
        ERC4626 vaultToken = ERC4626(_vaultToken);
        token.approve(_vaultToken, _amount);
        vaultToken.deposit(_amount, address(this));
        uint8 decimals = token.decimals();
        tokens[_vaultToken].balance += _amount * (10 ** (20 - decimals));
    }

    function withdraw(uint _id, uint _amount) public {
        address payee = ERC721(factory).ownerOf(_id);
        require(payee != address(0), "stream already burned");
        Stream storage stream = streams[_id];
        Token storage token = tokens[stream.vaultToken];
        ERC20 assetToken = ERC20(stream.token);
        ERC4626 vaultToken = ERC4626(stream.vaultToken);

        // Deduct payer balance since last update
        uint paidSinceUpdate = (block.timestamp - token.lastPayerUpdate) * token.totalPaidPerSec;
        if (token.balance >= paidSinceUpdate) {
            tokens[stream.vaultToken].balance -= paidSinceUpdate;
            tokens[stream.vaultToken].lastPayerUpdate = uint40(block.timestamp);
        } else {
            uint timePaid = token.balance / token.totalPaidPerSec;
            tokens[stream.vaultToken].lastPayerUpdate += uint40(timePaid);
            tokens[stream.vaultToken].balance = token.balance % token.totalPaidPerSec;
        }

        // Update stream
        uint available = (token.lastPayerUpdate - stream.lastUpdate) * stream.amountPerSec;
        require(available >= _amount, "amount > balance");
        tokens[stream.vaultToken].balance -= _amount;
        streams[_id].lastUpdate += uint40(_amount / stream.amountPerSec);

        // Redeem from pool 
        uint8 decimals = assetToken.decimals();
        uint toRedeem = _amount / (10 ** (20 - decimals));
        uint redeemed = vaultToken.redeem(toRedeem, address(this), address(this));

        // Send redeemed + earned yield /2 to payee and redeposit other half
        uint split = (redeemed - toRedeem) / 2;
        bool transferred = assetToken.transfer(payee, toRedeem + split);
        require(transferred, "transfer to payee failed");
        assetToken.approve(stream.vaultToken, split);
        vaultToken.deposit(split, address(this));
        tokens[stream.vaultToken].balance += split * (10 ** (20 - decimals));
    }

    function createStream(address _token, address _vaultToken, address _payee, uint216 _amountPerSec) external {
        require(msg.sender == owner, "not owner");
        require(_amountPerSec > 0, "cannot send 0 per sec");
        require(_payee != address(0), "cannot send to 0");
        require(_token != address(0), "token cannot be 0");
        require(_vaultToken != address(0), "vault token cannot be 0");
        require(_amountPerSec > 0, "amount per sec cannot be 0");
        
        // Update token info
        uint delta = block.timestamp - tokens[_vaultToken].lastPayerUpdate;
        tokens[_vaultToken].balance -= delta * tokens[ _vaultToken].totalPaidPerSec;
        tokens[_vaultToken].totalPaidPerSec += _amountPerSec;
        tokens[_vaultToken].lastPayerUpdate = uint40(block.timestamp);

        Factory nftFactory = Factory(factory);

        // Mint nft from factory then add stream info to contract
        uint id = nftFactory.mint(_payee);
        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            lastUpdate: uint40(block.timestamp),
            token: _token,
            vaultToken: _vaultToken
        });
    }


    function cancelStream(uint _id) external {
        address payee = ERC721(factory).ownerOf(_id);
        require(msg.sender == owner, "not owner");
        require(payee != address(0), "stream already burned");
        // Get withdrawable amount and burn nft, after that deduct totalPerSec of burned stream
        (uint withdrawableAmount) = withdrawable(_id); 
        withdraw(_id, withdrawableAmount);
        Factory nftFactory = Factory(factory);
        (bool burned) = nftFactory.burn(_id);
        require(burned, "failed to burn nft");
        tokens[streams[_id].vaultToken].totalPaidPerSec -= streams[_id].amountPerSec;
    }

    function modifyStream(uint _id, address _token, address _vaultToken, uint216 _amountPerSec) external {
        address payee = ERC721(factory).ownerOf(_id);
        require(msg.sender == owner, "not owner");
        require(payee != address(0), "stream already burned");
        require(_token != address(0), "token cannot be 0");
        require(_vaultToken != address(0), "vault token cannot be 0");
        require(_amountPerSec > 0, "amount per sec cannot be 0");
        // Withdraw and basically cancel the current stream
        (uint withdrawableAmount) = withdrawable(_id);
        withdraw(_id, withdrawableAmount);
        tokens[streams[_id].vaultToken].totalPaidPerSec -= streams[_id].amountPerSec;
        // Create a new stream
        uint delta = block.timestamp - tokens[_vaultToken].lastPayerUpdate;
        tokens[_vaultToken].balance -= delta * tokens[_vaultToken].totalPaidPerSec;
        tokens[_vaultToken].totalPaidPerSec += _amountPerSec;
        tokens[_vaultToken].lastPayerUpdate = uint40(block.timestamp);
        // Update current stream token
        streams[_id] = Stream({
            amountPerSec: _amountPerSec,
            lastUpdate: uint40(block.timestamp),
            token: _token,
            vaultToken: _vaultToken
        });
    }

    function withdrawPayer(address _token, address _vaultToken, uint _amount) external {
        ERC20 assetToken = ERC20(_token);
        ERC4626 vaultToken = ERC4626(_vaultToken);
        require(msg.sender == owner, "not owner");
        tokens[_vaultToken].balance -= _amount;
        uint delta = block.timestamp - tokens[_vaultToken].lastPayerUpdate;
        require(tokens[_vaultToken].balance >= delta * tokens[_vaultToken].totalPaidPerSec, "amount > balance");
        uint8 decimals = assetToken.decimals();
        uint toRedeem = _amount / (10 ** (20 - decimals));
        vaultToken.redeem(toRedeem, owner, address(this));
    }

    function transferOwnership(address _futureOwner) external {
        require(msg.sender == owner, "not owner");
        futureOwner = _futureOwner;
    }

    function applyTransferOwnership() external {
        require(msg.sender == futureOwner, "not future owner");
        owner = msg.sender;
    }

    function withdrawable(uint _id) public view returns (uint withdrawableAmount) {
        Stream storage stream = streams[_id];
        Token storage token = tokens[stream.vaultToken];
        uint paidSinceUpdate = (block.timestamp - token.lastPayerUpdate) * token.totalPaidPerSec;
        uint lastUpdate;
        if (token.balance >= paidSinceUpdate) {
            lastUpdate = block.timestamp;
        } else {
            lastUpdate = token.lastPayerUpdate + (token.balance / token.totalPaidPerSec);
        }
        withdrawableAmount = ((lastUpdate - stream.lastUpdate) * stream.amountPerSec);
    }



}