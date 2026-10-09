// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {QuakeBase} from "./base/QuakeBase.sol";
import {IInsuranceFund} from "./interfaces/IQuake.sol";

/// @title InsuranceFund
/// @notice Funded by a share of trading fees and liquidation penalties. Covers bad debt (reimbursing the LP
///         vault) and, as a second line, trader profit the vault cannot pay. Only COVER_ROLE (MarginAccount) can
///         draw; the Timelock can withdraw surplus.
contract InsuranceFund is QuakeBase, IInsuranceFund {
    using SafeERC20 for IERC20;

    bytes32 public constant COVER_ROLE = keccak256("COVER_ROLE");

    IERC20 public immutable token;

    event Covered(address indexed to, uint256 requested, uint256 paid);
    event Shortfall(uint256 uncovered);
    event Withdrawn(address indexed to, uint256 amount);

    constructor(address admin, IERC20 token_) QuakeBase(admin) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    function balance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @inheritdoc IInsuranceFund
    function cover(address to, uint256 amount) external override onlyRole(COVER_ROLE) nonReentrant returns (uint256 paid) {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balance();
        paid = amount > bal ? bal : amount;
        if (paid < amount) emit Shortfall(amount - paid);
        if (paid != 0) token.safeTransfer(to, paid);
        emit Covered(to, amount, paid);
    }

    function withdraw(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }
}
