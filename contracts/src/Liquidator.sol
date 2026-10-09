// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {QuakeBase} from "./base/QuakeBase.sol";
import {IMarginAccount} from "./interfaces/IQuake.sol";

interface ILiquidatableMarket {
    function liquidate(uint256 id, address beneficiary) external returns (uint256 reward);

    function isLiquidatable(uint256 id) external view returns (bool);
}

/// @title Liquidator
/// @notice Permissionless entry point for liquidations. Anyone may liquidate an unhealthy position in any
///         registered market and receives the liquidator share of the penalty. Batch calls are bounded and
///         skip positions that are not (or no longer) liquidatable instead of reverting.
contract Liquidator is QuakeBase {
    uint256 public constant MAX_BATCH = 25;

    IMarginAccount public immutable marginAccount;

    event LiquidationExecuted(address indexed market, uint256 indexed positionId, address indexed caller, uint256 reward);
    event LiquidationSkipped(address indexed market, uint256 indexed positionId);

    error UnknownMarket();
    error BatchTooLarge();

    constructor(address admin, IMarginAccount marginAccount_) QuakeBase(admin) {
        if (address(marginAccount_) == address(0)) revert ZeroAddress();
        marginAccount = marginAccount_;
    }

    function liquidate(address market, uint256 positionId) external whenNotPaused nonReentrant returns (uint256 reward) {
        if (!marginAccount.isMarket(market)) revert UnknownMarket();
        reward = ILiquidatableMarket(market).liquidate(positionId, msg.sender);
        emit LiquidationExecuted(market, positionId, msg.sender, reward);
    }

    function liquidateBatch(address market, uint256[] calldata positionIds)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 totalReward)
    {
        if (!marginAccount.isMarket(market)) revert UnknownMarket();
        uint256 len = positionIds.length;
        if (len > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < len; ++i) {
            try ILiquidatableMarket(market).liquidate(positionIds[i], msg.sender) returns (uint256 r) {
                totalReward += r;
                emit LiquidationExecuted(market, positionIds[i], msg.sender, r);
            } catch {
                emit LiquidationSkipped(market, positionIds[i]);
            }
        }
    }

    function isLiquidatable(address market, uint256 positionId) external view returns (bool) {
        if (!marginAccount.isMarket(market)) return false;
        return ILiquidatableMarket(market).isLiquidatable(positionId);
    }
}
