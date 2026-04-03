// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StakeLabToken is ERC20 {
    error ZeroAddress();

    constructor(address initialHolder, string memory name_, string memory symbol_, uint256 initialSupply)
        ERC20(name_, symbol_)
    {
        if (initialHolder == address(0)) revert ZeroAddress();

        _mint(initialHolder, initialSupply);
    }
}
