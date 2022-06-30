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

contract LlamaPayV2Payer {

    using SafeTransferLib for ERC20;

    struct Stream {
        uint216 amountPerSec;
        uint40 startsAt;
        address vault;
    }

    struct Vault {
        uint balance;
        uint216 totalPaidPerSec;
        uint40 lastUpdate;
    }

    mapping(address => Vault) vaults;
    mapping(uint => Stream) streams;

    address immutable public factory;
    address public owner;
    address public futureOwner;
    
    constructor(address _payer) {
        factory = msg.sender;
        owner = _payer;
    }

    function deposit(address _asset, address _vault, uint _amount) external {
        ERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        ERC20(_asset).safeApprove(_vault, _amount);
        ERC4626(_vault).deposit(_amount, address(this));
        uint decimals = ERC20(_asset).decimals();
        vaults[_vault].balance += _amount * (10 ** (20 - decimals));
    }

    function withdrawPayer(address _vault, uint _amount) external {
        require(msg.sender == owner, "not owner");
        vaults[_vault].balance -= _amount;
        uint yieldPerToken = yieldEarnedPerToken(_vault);
        uint alreadyStreamed = (block.timestamp - vaults[_vault].lastUpdate) * vaults[_vault].totalPaidPerSec;
        vaults[_vault].balance += alreadyStreamed * yieldPerToken;
        require(vaults[_vault].balance >= alreadyStreamed, "already streamed > balance");
        ERC20 asset = ERC4626(_vault).asset();
        uint8 decimals = asset.decimals();
        uint toWithdraw = _amount / (10 ** (20 - decimals));
        ERC4626(_vault).withdraw(toWithdraw, owner, address(this));
    }

    function _withdraw(uint _id, uint _amount) internal returns(uint toWithdraw) {
        Stream storage stream = streams[_id];
        Vault storage vault = vaults[stream.vault];

        uint paidSinceUpdate = (block.timestamp - vault.lastUpdate) * vault.totalPaidPerSec;
        if (vault.balance >= paidSinceUpdate) {
            vaults[stream.vault].balance -= paidSinceUpdate;
            vaults[stream.vault].lastUpdate = uint40(block.timestamp);
        } else {
            uint timePaid = vault.balance / vault.totalPaidPerSec;
            vaults[stream.vault].lastUpdate += uint40(timePaid);
            vaults[stream.vault].balance = vault.balance % vault.totalPaidPerSec;
        }

        uint yieldPerToken = yieldEarnedPerToken(stream.vault);
        uint available = (vault.lastUpdate - stream.startsAt) * stream.amountPerSec;
        uint streamYieldEarned = (available * yieldPerToken) / 2;
        available += streamYieldEarned;
        vaults[stream.vault].balance += streamYieldEarned;
        require(available >= _amount, "amount > available");
        vaults[stream.vault].balance -= _amount;
        uint streamTimePaid = _amount / stream.amountPerSec;
        streams[_id].startsAt+= uint40(streamTimePaid);
        ERC20 asset = ERC4626(stream.vault).asset();
        uint8 decimals = asset.decimals();
        toWithdraw = _amount / (10 ** (20 - decimals));
    }

    function withdraw(uint _id, uint _amount) public {
        require(streams[_id].startsAt != 0, "stream paused");
        address payee = ERC721(factory).ownerOf(_id);
        require(payee != address(0), "stream burned");
        (uint toWithdraw) = _withdraw(_id, _amount);
        ERC4626(streams[_id].vault).withdraw(toWithdraw, payee, address(this));
    }

    function createStream(address _vault, address _payee, uint216 _amountPerSec) external {
        require(msg.sender == owner, "not owner");
        require(_amountPerSec > 0, "cannot send 0 per sec");
        require(_payee != address(0), "cannot send to 0");
        require(_vault != address(0), "vault cannot be 0");
        require(_amountPerSec > 0, "amount per sec cannot be 0");
        
        vaults[_vault].balance -= (block.timestamp - vaults[_vault].lastUpdate) * vaults[_vault].totalPaidPerSec;
        vaults[_vault].totalPaidPerSec += _amountPerSec;
        vaults[_vault].lastUpdate = uint40(block.timestamp);

        uint id = Factory(factory).mint(_payee);
        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            startsAt: uint40(block.timestamp),
            vault: _vault
        });
    }

    function cancelStream(uint _id) external {
        address payee = ERC721(factory).ownerOf(_id);
        require(msg.sender == owner, "not owner");
        require( payee != address(0), "stream already burned");
        Stream storage stream = streams[_id];
        uint withdrawableAmount = withdrawable(_id);
        uint toWithdraw = _withdraw(_id, withdrawableAmount);
        ERC4626(stream.vault).withdraw(toWithdraw, payee, address(this));
        bool burned = Factory(factory).burn(_id);
        require(burned, "failed to burn stream");
        vaults[stream.vault].totalPaidPerSec -= stream.amountPerSec;
    }

    function modifyStream(uint _id, address _newVault, address _newPayee, uint216 _newAmountPerSec) external {
        address payee = ERC721(factory).ownerOf(_id);
        require(msg.sender == owner, "not owner");
        require(payee != address(0), "stream already burned");
        require(_newVault != address(0), "new vault cannot be 0");
        require(_newPayee != address(0), "new payee cannot be 0");
        require(_newAmountPerSec > 0, "new amtpersec needs to be > 0");

        uint withdrawableAmount =  withdrawable(_id);
        withdraw(_id, withdrawableAmount);
        vaults[streams[_id].vault].totalPaidPerSec -= streams[_id].amountPerSec;

        vaults[_newVault].balance -= (block.timestamp - vaults[_newVault].lastUpdate) * vaults[_newVault].totalPaidPerSec;
        vaults[_newVault].totalPaidPerSec += _newAmountPerSec;
        vaults[_newVault].lastUpdate = uint40(block.timestamp);

        streams[_id] = Stream({
            amountPerSec: _newAmountPerSec,
            startsAt: uint40(block.timestamp),
            vault: _newVault
        });

        if (_newPayee != payee) {
            ERC721(factory).safeTransferFrom(payee, _newPayee, _id);
        }
    }

    function pauseStream(uint _id) external {
        require(msg.sender == owner, "not owner");
        require(ERC721(factory).ownerOf(_id) != address(0), "stream burned");

        uint withdrawableAmount =  withdrawable(_id);
        withdraw(_id, withdrawableAmount);
        vaults[streams[_id].vault].totalPaidPerSec -= streams[_id].amountPerSec;
        streams[_id].startsAt = 0;
    }

    function resumeStream(uint _id) external {
       require(msg.sender == owner, "not owner");
       require(ERC721(factory).ownerOf(_id) != address(0), "stream burned");
       
        Stream storage stream = streams[_id];

        vaults[stream.vault].balance -= (block.timestamp - vaults[stream.vault].lastUpdate);
        vaults[stream.vault].totalPaidPerSec += stream.amountPerSec;
        vaults[stream.vault].lastUpdate = uint40(block.timestamp);
        streams[_id].startsAt = uint40(block.timestamp);
    }

    function transferOwnership(address _futureOwner) external {
        require(msg.sender == owner, "not owner");
        futureOwner = _futureOwner;
    }

    function applyTransferOwnership() external {
        require(msg.sender == futureOwner, "not future owner");
        owner = msg.sender;
    }

    function yieldEarnedPerToken(address _vault) public view returns(uint earned) {
        Vault storage vault = vaults[_vault];
        uint shares = ERC4626(_vault).balanceOf(address(this));
        uint sharesToAssets = ERC4626(_vault).convertToAssets(shares);
        earned = (sharesToAssets / vault.balance) / vault.balance;
    }

    function withdrawable(uint _id) public view returns (uint withdrawableAmount) {
        Stream storage stream = streams[_id];
        Vault storage vault = vaults[stream.vault];
        uint paidSinceUpdate = (block.timestamp - vault.lastUpdate) * vault.totalPaidPerSec;
        uint lastPayerUpdate;
        if (vault.balance >= paidSinceUpdate) {
            lastPayerUpdate = block.timestamp;
        } else {
            lastPayerUpdate = vault.lastUpdate + (vault.balance / vault.totalPaidPerSec);
        }
        uint yieldPerToken = yieldEarnedPerToken(stream.vault);
        withdrawableAmount = lastPayerUpdate - vault.lastUpdate * stream.amountPerSec;
        uint streamYieldEarned = (withdrawableAmount * yieldPerToken) / 2;
        withdrawableAmount += streamYieldEarned;
    }


}