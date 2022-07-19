//SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.0;

import {ERC721} from "solmate/tokens/ERC721.sol";
import "./LlamaPayV2Payer.sol";

/// @title LlamaPay V2 Factory Contract
/// @author nemusona
contract LlamaPayV2Factory is ERC721("LlamaPayV2-Stream", "LLAMA-V2-STREAM") {

    uint public tokenId;
    uint public llamaPayIndex;
    address public payer;
    address immutable public bot = address(0); // Add something here in the future

    mapping(address => address) public ownerToContract;
    mapping(uint => address) public indexToContract;
    mapping(address => bool) public validContract;
    mapping(uint => address) public tokenToContract;

    event LlamaPayContractCreated(address payer, address llamaPayContract);

    /// @notice create a llamapay contract
    function createLlamaPayContract() external returns (LlamaPayV2Payer llamaPayContract) {
        require(ownerToContract[msg.sender] == address(0), "contract already exists");
        payer = msg.sender;
        llamaPayContract = new LlamaPayV2Payer();
        address llamapay = address(llamaPayContract);
        ownerToContract[msg.sender] = llamapay;
        validContract[llamapay] = true;
        indexToContract[llamaPayIndex] = llamapay;

        unchecked {
            llamaPayIndex++;
        }

        emit LlamaPayContractCreated(msg.sender, llamapay);
    }

    /// @notice mint new stream token for payee
    /// @param _recipient payee
    function mint(address _recipient) external returns (bool, uint id) {
        require(validContract[msg.sender], "not payer contract");

        id = tokenId;
        _safeMint(_recipient, id);

        tokenToContract[id] = msg.sender;

        unchecked {
            tokenId++;
        }

        return (true, id);
    }

    /// @notice burn token
    /// @param _id token id
    function burn(uint _id) external returns (bool) {
        require(msg.sender == tokenToContract[_id], "not payer contract");
        _burn(_id);
        return true;
    }

    /// @notice transfer llamapay contract owner
    /// @param _from contract owner
    /// @param _to new contract owner
    function transferLlamaPayContract(address _from, address _to) external returns (bool) {
        require(validContract[msg.sender], "not payer contract");
        require(ownerToContract[_to] == address(0), "new owner already has an existing contract");
        ownerToContract[_from] = address(0);
        ownerToContract[_to] = msg.sender;
        return true;
    }

    function tokenURI(uint _id) public view virtual override returns (string memory) {
        return "";
    }

}