// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

contract LlamaVault is ERC4626{
    constructor(ERC20 _asset) ERC4626(_asset, "LlamaVault", "vLLAMA"){}

    function totalAssets() public view virtual override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}