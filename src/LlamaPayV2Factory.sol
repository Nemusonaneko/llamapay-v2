//SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.0;

import {ERC721} from "solmate/tokens/ERC721.sol";
import "./LlamaPayV2Payer.sol";

/// @title LlamaPay V2 Factory Contract
/// @author nemusona
contract LlamaPayV2Factory is ERC721("LlamaPayV2-Stream", "LLAMA-V2-STREAM") {

    uint public tokenId;
    uint public llamaPayIndex;
    address public parameter;

    mapping(uint => address) public llamaPayContracts;
    mapping(address => uint) public llamaPayAddressToIndex;
    mapping(uint => address) public tokenIdToLlamaPayAddress;

    constructor() {
        llamaPayIndex = 1;
        tokenId = 1;
    }

    /// @notice create a llamapay contract for payer
    /// @param _payer owner of new contract
    function createLlamaPayContract(address _payer) external returns(LlamaPayV2Payer payerContract) {
        unchecked {
            parameter = _payer;
            payerContract = new LlamaPayV2Payer();
            address llamapay = address(payerContract);
            llamaPayContracts[llamaPayIndex] = llamapay;
            llamaPayAddressToIndex[llamapay] = llamaPayIndex;
            llamaPayIndex++;
        }
    }

    /// @notice mint new stream token for payee
    /// @param _recipient payee
    function mint(address _recipient) external returns (bool, uint id) {
        require(llamaPayAddressToIndex[msg.sender] != 0, "msg.sender not payer contract");
        unchecked {    
            id = tokenId;
            _safeMint(_recipient, id);
            tokenIdToLlamaPayAddress[id] = msg.sender;
            tokenId++;
        }
        return (true, id);
    }

     /// @notice burn existing stream when cancelled
    /// @param _id token id
    function burn(uint _id) external returns (bool) {
        require(msg.sender == tokenIdToLlamaPayAddress[_id], "msg.sender not payer contract");
        unchecked {
            _burn(_id);
        }
        return true;
    }

    function transferToken( address _from, address _to, uint _id) external returns (bool) {
        require(msg.sender == tokenIdToLlamaPayAddress[_id], "msg.sender not payer contract");
        unchecked {
            safeTransferFrom(_from, _to, _id);
        }
        return true;
    }

     function tokenURI(uint _id) public view virtual override returns (string memory) {
        return "";
     }

}