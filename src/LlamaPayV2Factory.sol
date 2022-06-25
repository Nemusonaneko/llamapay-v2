//SPDX-License-Identifier: None

pragma solidity ^0.8.0;

import {ERC721} from "solmate/tokens/ERC721.sol";
import "./LlamaPayV2Payer.sol";

contract LlamaPayV2Factory is ERC721("LlamaPayV2-Stream", "LLAMA-V2-STREAM") {

    uint public tokenId;
    uint public llamaPayIndex;

    mapping(uint => address) llamaPayContracts;
    mapping(address => uint) llamaPayAddressToIndex;
    mapping(uint => address) tokenIdToLlamaPayAddress;

    constructor() {
        llamaPayIndex = 1;
        tokenId = 1;
    }

    function createLlamaPayContract(address _payer) external {
        address llamapay = address(new LlamaPayV2Payer(_payer));
        llamaPayContracts[llamaPayIndex] = llamapay;
        llamaPayAddressToIndex[llamapay] = llamaPayIndex;
        unchecked {
            llamaPayIndex++;
        }
    }

    function mint(address _recipient) external returns (uint id) {
        require(llamaPayAddressToIndex[msg.sender] != 0, "msg.sender not payer contract");
        id = tokenId;
        _safeMint(_recipient, id);
        unchecked {    
            tokenIdToLlamaPayAddress[id] = msg.sender;
            tokenId++;
        }
        return id;
    }

    function burn(uint _id) external returns (bool) {
        require(msg.sender == tokenIdToLlamaPayAddress[_id], "msg.sender not payer contract");
        _burn(_id);
        return true;
    }

     function tokenURI(uint _id) public view virtual override returns (string memory) {
        return "llama";
     }

}