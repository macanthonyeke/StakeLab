// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract protocolTreasury is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(WITHDRAW_ROLE, admin);
    }

    function withdrawToken(IERC20 token, address recipient, uint256 amount)
        external
        onlyRole(WITHDRAW_ROLE)
        nonReentrant
    {
        token.safeTransfer(recipient, amount);
    }
}
