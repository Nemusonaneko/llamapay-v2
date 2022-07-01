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
contract LlamaPayV2Payer {

    using SafeTransferLib for ERC20;

    struct Stream {
        uint earnedYield;
        uint216 amountPerSec;
        uint40 lastUpdate;
    }

    struct Token {
        uint balance;
        uint earnedYield;
        uint216 totalPaidPerSec;
        uint40 lastUpdate;
    }

    address immutable public factory;
    address public owner;
    address public futureOwner;

    mapping(address => Token) tokens;
    mapping(uint => Stream) streams;
    mapping(uint => address) vaults; // Maps streamId to vault where the streamed tokens are earning yield
    
    constructor(address _payer) {
        factory = msg.sender;
        owner = _payer;
    }

    /// @notice updates vault balances and earned yield
    /// @param _vault vault to be updated
    function _updateVault(address _vault) private {
        uint delta = block.timestamp - tokens[_vault].lastUpdate;
        uint streamedSinceUpdate = delta * tokens[_vault].totalPaidPerSec;
        uint earnedPerToken = yieldEarnedPerToken(_vault);
        if (tokens[_vault].balance >= streamedSinceUpdate) {
            tokens[_vault].balance -= streamedSinceUpdate;
            tokens[_vault].earnedYield += streamedSinceUpdate * earnedPerToken;
            tokens[_vault].lastUpdate = uint40(block.timestamp);
        } else {
            uint timePaid = tokens[_vault].balance / tokens[_vault].totalPaidPerSec;
            uint tokensStreamed = timePaid * tokens[_vault].totalPaidPerSec;
            tokens[_vault].balance -= tokensStreamed;
            tokens[_vault].earnedYield += tokensStreamed * earnedPerToken;
            tokens[_vault].lastUpdate += uint40(timePaid);
        }
    }

    /// @notice Deposit into payer contract. Allows for deposit on behalf of owner.
    /// @param _asset the underlying token to be deposited into vault
    /// @param _vault the ERC4626 vault token to deposit into
    /// @param _amount amount of tokens to deposit
    function deposit(address _asset, address _vault, uint _amount) external {
        ERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        ERC20(_asset).safeApprove(_vault, _amount);
        ERC4626(_vault).deposit(_amount, address(this));
        uint8 decimals = ERC20(_asset).decimals();
        tokens[_vault].balance += _amount * (10 ** (20 - decimals));
    } 

    /// @notice Withdraw a certain amount of unstreamed tokens for payer
    /// @param _vault vault to withdraw from
    /// @param _amount amount to withdraw (20 decimals)
    function withdrawPayer(address _vault, uint _amount) external {
        require(msg.sender == owner, "not owner");

        _updateVault(_vault);
        uint delta = block.timestamp - tokens[_vault].lastUpdate;
        uint amountPaid = delta * tokens[_vault].totalPaidPerSec;
        tokens[_vault].balance -= _amount;

        require(tokens[_vault].balance >= amountPaid, "already streamed > available");
        ERC20 asset = ERC4626(_vault).asset();
        uint toWithdraw = _amount / (10 ** (20 - asset.decimals()));
        ERC4626(_vault).withdraw(toWithdraw, owner, address(this));
    }

    /// @notice Withdraw earned yield for payee
    /// @param _vault vault to withdraw from
    function withdrawPayerYield(address _vault) external {
        require(msg.sender == owner, "not owner");
        _updateVault(_vault);
        ERC20 asset = ERC4626(_vault).asset();
        uint toWithdraw = tokens[_vault].earnedYield / (10 ** (20 - asset.decimals()));
        tokens[_vault].earnedYield = 0;
        ERC4626(_vault).withdraw(toWithdraw, owner, address(this));
    }

    /// @notice Withdraw streamed tokens for payee
    /// @param _id token id
    /// @param _amount amount to withdraw (20 decimals)
    function withdraw(uint _id, uint _amount) external {
        require(streams[_id].lastUpdate != 0, "stream paused");
        address payee = ERC721(factory).ownerOf(_id);
        require(payee != address(0), "stream burned");
        _updateVault(vaults[_id]);
        uint delta = tokens[vaults[_id]].lastUpdate - streams[_id].lastUpdate;
        uint available = delta * streams[_id].amountPerSec;
        uint earnedPerToken = yieldEarnedPerToken(vaults[_id]);
        streams[_id].earnedYield += available * earnedPerToken;
        require(available >= _amount, "amount > available");
        streams[_id].lastUpdate += uint40(_amount / streams[_id].amountPerSec);
        ERC20 asset = ERC4626(vaults[_id]).asset();
        uint toWithdraw = _amount / (10 ** (20 - asset.decimals()));
        ERC4626(vaults[_id]).withdraw(toWithdraw, payee, address(this));
    } 

    /// @notice Withdraw earned yield for payee
    /// @param _id token id
    function withdrawYield(uint _id) external {
        address payee = ERC721(factory).ownerOf(_id);
        require(payee != address(0), "stream burned");
        _updateVault(vaults[_id]);
        uint delta = tokens[vaults[_id]].lastUpdate - streams[_id].lastUpdate;
        uint available = delta * streams[_id].amountPerSec;
        uint earnedPerToken = yieldEarnedPerToken(vaults[_id]);
        streams[_id].earnedYield += available * earnedPerToken;
        ERC20 asset = ERC4626(vaults[_id]).asset();
        uint toWithdraw =  streams[_id].earnedYield / (10 ** (20 - asset.decimals()));
        streams[_id].earnedYield = 0;
        ERC4626(vaults[_id]).withdraw(toWithdraw, payee, address(this));
    }

    /// @notice creates a new stream for payee
    /// @param _vault vault that tokens are earning yield and streamed from
    /// @param _payee recipient of stream
    /// @param _amountPerSec amount streamed per second (20 decimals)
    function createStream(address _vault, address _payee, uint216 _amountPerSec) external {
        require(msg.sender == owner, "not owner");
        require(_payee != address(0), "cannot send to 0");
        require(_vault != address(0), "vault cannot be 0");
        require(_amountPerSec > 0, "amount per sec cannot be 0");

        _updateVault(_vault);
        require(tokens[_vault].lastUpdate == block.timestamp, "payer in debt");
        tokens[_vault].totalPaidPerSec += _amountPerSec;
        uint id = Factory(factory).mint(_payee);
        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            lastUpdate: uint40(block.timestamp),
            earnedYield: 0
        });
        vaults[id] = _vault;
    }

    /// @notice cancel and burn stream for payee
    /// @param _id token ID
    function cancelStream(uint _id) external {
        address payee = ERC721(factory).ownerOf(_id);
        address vault = vaults[_id];
        require(msg.sender == owner, "not owner");
        require( payee != address(0), "stream already burned");
        _updateVault(vault);
        (uint withdrawableAmt, uint yieldEarned) = withdrawable(_id);
        uint toWithdraw = withdrawableAmt + yieldEarned;
        ERC4626(vault).withdraw(toWithdraw, payee, address(this));
        bool burned = Factory(factory).burn(_id);
        require(burned, "failed to burn stream");
        tokens[vault].totalPaidPerSec -= streams[_id].amountPerSec;
    }

    /// @notice modify stream for payee
    /// @param _id token id
    /// @param _newVault new vault for yield and streaming
    /// @param _newPayee new payee to stream to 
    /// @param _newAmountPerSec new AmtPerSec to stream (20 decimals)
    function modifyStream(uint _id, address _newVault, address _newPayee, uint216 _newAmountPerSec) external {
        address payee = ERC721(factory).ownerOf(_id);
        require(msg.sender == owner, "not owner");
        require(payee != address(0), "stream already burned");
        require(_newVault != address(0), "new vault cannot be 0");
        require(_newPayee != address(0), "new payee cannot be 0");
        require(_newAmountPerSec > 0, "new amtpersec needs to be > 0"); 

        _updateVault(vaults[_id]);
        (uint withdrawableAmt, uint yieldEarned) = withdrawable(_id);
        uint toWithdraw = withdrawableAmt + yieldEarned;
        ERC4626(vaults[_id]).withdraw(toWithdraw, payee, address(this));
        tokens[vaults[_id]].totalPaidPerSec -= streams[_id].amountPerSec;

        _updateVault(_newVault);
        require(tokens[_newVault].lastUpdate == block.timestamp, "payer in debt");
        tokens[_newVault].totalPaidPerSec += _newAmountPerSec;
        vaults[_id] = _newVault;

        streams[_id] = Stream({
            amountPerSec: _newAmountPerSec,
            lastUpdate: uint40(block.timestamp),
            earnedYield: 0
        });

        if (_newPayee != payee) {
            ERC721(factory).safeTransferFrom(payee, _newPayee, _id);
        }
    }

    /// @notice "cancel stream" without burning the nft so you can resume it later
    /// @param _id token id
    function pauseStream(uint _id) external {
        address payee = ERC721(factory).ownerOf(_id);
        require(msg.sender == owner, "not owner");
        require(payee != address(0), "stream burned");
        _updateVault(vaults[_id]);
        (uint withdrawableAmt, uint yieldEarned) = withdrawable(_id);
        uint toWithdraw = withdrawableAmt + yieldEarned;
        ERC4626(vaults[_id]).withdraw(toWithdraw, payee, address(this));
        tokens[vaults[_id]].totalPaidPerSec -= streams[_id].amountPerSec;
        streams[_id].lastUpdate = 0;
    }

    /// @notice resume a paused stream
    /// @param _id token id
    function resumeStream(uint _id) external {
       require(msg.sender == owner, "not owner");
       require(ERC721(factory).ownerOf(_id) != address(0), "stream burned");
       require(streams[_id].lastUpdate == 0, "stream is not paused");
       
       _updateVault(vaults[_id]);
       require(tokens[vaults[_id]].lastUpdate == block.timestamp, "payer in debt");
       streams[_id].lastUpdate = uint40(block.timestamp);
       tokens[vaults[_id]].totalPaidPerSec += streams[_id].amountPerSec;
    }

    /// @notice Change future owner 
    /// @param _futureOwner futuer owner
    function transferOwnership(address _futureOwner) external {
    require(msg.sender == owner, "not owner");
        futureOwner = _futureOwner;
    }

    /// @notice Apply future owner as current owner
    function applyTransferOwnership() external {
        require(msg.sender == futureOwner, "not future owner");
        owner = msg.sender;
    }

    /// @notice Get share of yield per token earned by tokens deposited by this contract
    /// (redeemable assets - deposited assets) / deposited assets = yield earned per token
    /// @param _vault vault to query
    /// @return earnedPerToken amount of yield earned per token deposited (native decimals)
    function yieldEarnedPerToken(address _vault) public view returns (uint earnedPerToken) {
        uint shares = ERC4626(_vault).balanceOf(address(this));
        ERC20 asset = ERC4626(_vault).asset();
        uint deposited = tokens[_vault].balance / (10 ** (20 - asset.decimals()));
        uint redeemable = ERC4626(_vault).convertToAssets(shares);
        earnedPerToken = ((redeemable - deposited) / deposited) / 2;
    }

    /// @notice Get withdrawable amount from specific stream 
    /// @param _id token ID for stream
    /// @return withdrawableAmt amount available for withdrawal (native decimals)
    /// @return yieldEarned yield available for withdrawal (native decimals)
    function withdrawable(uint _id) public view returns (uint withdrawableAmt, uint yieldEarned) {
        uint earnedPerToken = yieldEarnedPerToken(vaults[_id]);
        uint delta = block.timestamp - tokens[vaults[_id]].lastUpdate;
        uint streamedSinceUpdate = delta * tokens[vaults[_id]].totalPaidPerSec;
        uint lastPayerUpdate;
        if (tokens[vaults[_id]].balance >= streamedSinceUpdate) {
            lastPayerUpdate = block.timestamp;
        } else {
            lastPayerUpdate = tokens[vaults[_id]].lastUpdate + (tokens[vaults[_id]].balance/ tokens[vaults[_id]].totalPaidPerSec);
        }
        uint payeeDelta = (lastPayerUpdate - streams[_id].lastUpdate);
        ERC20 asset = ERC4626(vaults[_id]).asset();
        uint8 decimals = asset.decimals();
        withdrawableAmt = (payeeDelta * streams[_id].amountPerSec) / (10 ** (20 - decimals));
        yieldEarned = (streams[_id].earnedYield + (withdrawableAmt * earnedPerToken)) / (10 ** (20 - decimals));
    }
}