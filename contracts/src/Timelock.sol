// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title QuakeTimelock
/// @notice 48-hour TimelockController that holds DEFAULT_ADMIN_ROLE on every Quakemeter contract.
///         Self-administered (no admin address): role changes must themselves go through the delay.
contract QuakeTimelock is TimelockController {
    uint256 public constant MIN_DELAY = 48 hours;

    constructor(address[] memory proposers, address[] memory executors)
        TimelockController(MIN_DELAY, proposers, executors, address(0))
    {}
}
