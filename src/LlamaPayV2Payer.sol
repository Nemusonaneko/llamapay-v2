//SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "forge-std/console.sol";

interface Factory {
    function payer() external view returns (address);
    function bot() external view returns (address);
    function ownerToContract(address) external view returns (address);
    function mint(address _recipient) external returns (bool, uint id);
    function burn(uint id) external returns (bool);
    function transferToken( address _from, address _to, uint _id) external returns (bool);
    function transferLlamaPayContract(address _from, address _to) external returns (bool);
}

/// @title LlamaPay V2 Payer Contract
/// @author nemusona
contract LlamaPayV2Payer {

    using SafeTransferLib for ERC20;

    struct Stream {
        uint216 amountPerSec;
        uint40 lastStreamUpdate;
    }

    struct Vault {
        uint balance;
        uint deposited;
        uint40 lastUpdate;
        uint216 totalPaidPerSec;
    }

    address immutable public factory;
    address immutable public bot;
    address public owner;
    address public futureOwner;

    mapping(address => Vault) public vaults;
    mapping(uint => Stream) public streams;
    mapping(uint => address) public streamedFrom;

    event Deposit(address indexed from, address indexed token, address indexed vault, uint amount);
    event PayerWithdraw(address indexed vault, uint amount);
    event Withdraw(uint id, uint amount, address indexed payee);
    event StreamCreated(uint id, address indexed vault, address indexed payee, uint216 amountPerSec);
    event StreamCancelled(uint id);
    event StreamPaused(uint id);
    event StreamResumed(uint id);
    event StreamModified(uint id, uint216 newAmountPerSec);
    event OwnershipTransferred(address indexed from, address indexed to);
    event OwnershipApplied(address indexed owner);

    constructor() {
        factory = msg.sender;
        owner = Factory(msg.sender).payer();
        bot = Factory(msg.sender).bot();
    }

    /// @notice Deposit into payer contract. Allows for deposit on behalf of owner.
    /// @param _token the token to be streamed
    /// @param _vault the ERC4626 vault token to deposit into
    /// @param _amount amount of tokens to deposit into vault
    function deposit(address _token, address _vault, uint _amount) external {
        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        ERC20(_token).safeApprove(_vault, _amount); 
        ERC4626(_vault).deposit(_amount, address(this));
        uint8 decimals = ERC20(_token).decimals();
        uint toAdd;
        unchecked {
            toAdd = _amount * (10 ** (20 - decimals));
        }
        vaults[_vault].balance += toAdd;
        vaults[_vault].deposited += toAdd;

        emit Deposit(msg.sender, _token, _vault, _amount);
    }

    /// @notice updates vault balances and distribute yield to payer
    /// @param _vault vault to be updated
    function _updateVault(address _vault) private {
        uint totalPaidPerSec = vaults[_vault].totalPaidPerSec;
        uint delta = block.timestamp - vaults[_vault].lastUpdate;
        uint balance = vaults[_vault].balance;
        unchecked {
            uint totalStreamed = delta * totalPaidPerSec;
            if (balance >= totalStreamed) {
                vaults[_vault].balance -= totalStreamed;
                vaults[_vault].lastUpdate = uint40(block.timestamp);
            } else {
                uint timePaid = balance / totalPaidPerSec;
                vaults[_vault].balance = balance % totalPaidPerSec;
                vaults[_vault].lastUpdate += uint40(timePaid);
            }  
        }
    }

    /// @notice withdraw unstreamed tokens from vault
    /// @param _vault vault to withdraw from
    /// @param _amount amount to withdraw (20 decimals)
    function withdrawPayer(address _vault, uint _amount) external {
        require(msg.sender == owner, "not owner");
        
        _updateVault(_vault);
        vaults[_vault].balance -= _amount;
        vaults[_vault].deposited -= _amount;

        require(block.timestamp == vaults[_vault].lastUpdate, "in debt");

        uint8 decimals = ERC4626(_vault).asset().decimals();
        uint toWithdraw;
        unchecked {
            toWithdraw = _amount / (10 ** (20 - decimals));
        }
        ERC4626(_vault).withdraw(toWithdraw, owner, address(this));

        emit PayerWithdraw(_vault, _amount);
    }

    /// @notice withdraw tokens to payee
    /// @param _id token id to withdraw
    /// @param _amount amount to withdraw (20 decimals)
    function withdraw(uint _id, uint _amount) public {
        Stream storage stream = streams[_id];
        require(stream.lastStreamUpdate > 0, "stream paused");

        address from = streamedFrom[_id];
        address payee = ERC721(factory).ownerOf(_id);
        require(payee != address(0), "stream burned");
        uint earnedPerToken;
        unchecked {
            earnedPerToken = getEarnedPerToken(from) / 2;
        }
        _updateVault(from);
        Vault storage vault = vaults[from];
        uint delta = vault.lastUpdate - stream.lastStreamUpdate;
        uint availableToWithdraw;
        unchecked {
            availableToWithdraw = delta * stream.amountPerSec;
        }
        require(availableToWithdraw >= _amount, "available < amount to withdraw");
        uint8 decimals = ERC4626(from).asset().decimals();
        uint toWithdraw;
        uint yieldEarned;
        unchecked {
            streams[_id].lastStreamUpdate += uint40(_amount / stream.amountPerSec);
            yieldEarned = _amount * earnedPerToken;
            toWithdraw = (_amount + yieldEarned) / (10 ** (20 - decimals));
        }
        vaults[from].balance += yieldEarned;
        vaults[from].deposited -= _amount;
        
        ERC4626(from).withdraw(toWithdraw, payee, address(this));
        emit Withdraw(_id, toWithdraw, payee);
    }

    function createStream(address _vault, address _payee, uint216 _amountPerSec) external {
        require(msg.sender == owner || msg.sender == bot, "not owner or bot");
        require(_payee != address(0), "cannot send to 0");
        require(_vault != address(0), "vault cannot be 0");
        require(_amountPerSec > 0, "amount per sec cannot be 0");

        _updateVault(_vault);
        require(vaults[_vault].lastUpdate == block.timestamp, "in debt");
        (bool minted, uint id) = Factory(factory).mint(_payee);
        require(minted, "failed to mint token");
        vaults[_vault].totalPaidPerSec += _amountPerSec;
        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            lastStreamUpdate: uint40(block.timestamp)
        });
        streamedFrom[id] = _vault;

        emit StreamCreated(id, _vault, _payee, _amountPerSec);
    }

    /// @notice cancel and burn stream
    /// @param _id token id
    function cancelStream(uint _id) external {
        require(msg.sender == owner || msg.sender == bot, "not owner or bot");
        uint withdrawable = getWithdrawable(_id);
        withdraw(_id, withdrawable);
        vaults[streamedFrom[_id]].totalPaidPerSec -= streams[_id].amountPerSec;
        streams[_id].amountPerSec = 0;
        streams[_id].lastStreamUpdate = 0;
        bool burned = Factory(factory).burn(_id);
        require(burned, "failed to burn stream");

        emit StreamCancelled(_id);
    }

    /// @notice "cancel stream" without burning the nft so you can resume it later
    /// @param _id token id
    function pauseStream(uint _id) external {
        require(msg.sender == owner, "not owner");
        uint withdrawable = getWithdrawable(_id);
        withdraw(_id, withdrawable);
        vaults[streamedFrom[_id]].totalPaidPerSec -= streams[_id].amountPerSec;
        streams[_id].lastStreamUpdate = 0;

        emit StreamPaused(_id);
    }
    /// @notice resume a paused stream essentially creating stream without minting new token
    /// @param _id token id
    function resumeStream(uint _id) external {
        require(msg.sender == owner, "not owner");
        require(ERC721(factory).ownerOf(_id) != address(0), "stream burned");
        Stream storage stream = streams[_id];
        require(stream.lastStreamUpdate == 0, "stream is not paused");
        address vault = streamedFrom[_id];
        _updateVault(vault);
        require(vaults[vault].lastUpdate == block.timestamp, "in debt");
        streams[_id].lastStreamUpdate = uint40(block.timestamp);
        vaults[vault].totalPaidPerSec += stream.amountPerSec;

        emit StreamResumed(_id);
    }

    function modifyStream(uint _id, uint216 _newAmountPerSec) external {
        require(msg.sender == owner, "not owner");

        uint withdrawable = getWithdrawable(_id);
        withdraw(_id, withdrawable);

        address from = streamedFrom[_id];
        require(vaults[from].lastUpdate == block.timestamp, "payer in debt");
        vaults[from].totalPaidPerSec -= streams[_id].amountPerSec;
        vaults[from].totalPaidPerSec += _newAmountPerSec;
        streams[_id].amountPerSec = _newAmountPerSec;
        streams[_id].lastStreamUpdate = uint40(block.timestamp);

        emit StreamModified(_id, _newAmountPerSec);
    }

    /// @notice Change future owner 
    /// @param _futureOwner future owner
    function transferOwnership(address _futureOwner) external {
        require(msg.sender == owner, "not owner");
        require(Factory(factory).ownerToContract(_futureOwner) == address(0), "future owner already has an existing contract");
        futureOwner = _futureOwner;
        emit OwnershipTransferred(owner, _futureOwner);
    }

    /// @notice Apply future owner as current owner
    function applyTransferOwnership() external {
        require(msg.sender == futureOwner, "not future owner");
        bool transferred = Factory(factory).transferLlamaPayContract(owner, futureOwner);
        require(transferred, "failed to transfer ownership");
        owner = msg.sender;
        emit OwnershipApplied(owner);
    }

    /// @notice gets yield earned per token 
    /// @param _vault vault
    /// @return earnedPerToken yield earned per token (20 decimals)
    function getEarnedPerToken(address _vault) public view returns (uint earnedPerToken) {
        uint8 decimals = ERC4626(_vault).asset().decimals();
        uint shares = ERC4626(_vault).balanceOf(address(this));
        uint redeemable = ERC4626(_vault).convertToAssets(shares);
        redeemable = redeemable * (10 ** (20 - decimals));
        uint deposited = vaults[_vault].deposited;
        earnedPerToken = (redeemable - deposited) / deposited;
    }

    /// @notice withdrawable tokens from stream id
    /// @param _id token id 
    /// @return withdrawable (20 decimals)
    function getWithdrawable(uint _id) public view returns (uint withdrawable) {
        Stream storage stream = streams[_id];
        Vault storage vault = vaults[streamedFrom[_id]];
        uint delta = block.timestamp - vault.lastUpdate;
        uint totalStreamed = delta * vault.totalPaidPerSec;
        uint lastPayerUpdate;
        if (vault.balance >= totalStreamed) {
            lastPayerUpdate = block.timestamp;
        } else {
            lastPayerUpdate = vault.lastUpdate + (vault.balance / vault.totalPaidPerSec);
        }
        withdrawable = delta * stream.amountPerSec;
    }

    /// @notice get yield earned from stream
    /// @param _id token id
    /// @return yieldEarnedByStream yield earned (20 decimals)
    function getYieldEarnedByStream(uint _id) external view returns (uint yieldEarnedByStream) {
        uint withdrawable = getWithdrawable(_id);
        uint earnedPerToken = getEarnedPerToken(streamedFrom[_id]);
        yieldEarnedByStream = withdrawable * earnedPerToken;
    }

}