// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ICompliance} from "./interfaces/IQuake.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist hook. OFF by default (everyone allowed). When enabled by the Timelock, only
///         allowlisted accounts can deposit margin, open/increase positions, provide LP liquidity or enter
///         variance swaps. Exits (close, withdraw, settle) are never gated so funds cannot be trapped.
contract ComplianceRegistry is AccessControl, ICompliance {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(address => bool) public allowlisted;

    event EnabledSet(bool enabled);
    event AllowlistSet(address indexed account, bool allowed);

    error BatchTooLarge();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
    }

    function setEnabled(bool enabled_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = enabled_;
        emit EnabledSet(enabled_);
    }

    function setAllowlisted(address[] calldata accounts, bool allowed) external onlyRole(COMPLIANCE_ROLE) {
        uint256 len = accounts.length;
        if (len > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < len; ++i) {
            allowlisted[accounts[i]] = allowed;
            emit AllowlistSet(accounts[i], allowed);
        }
    }

    function isAllowed(address account) external view override returns (bool) {
        return !enabled || allowlisted[account];
    }
}
