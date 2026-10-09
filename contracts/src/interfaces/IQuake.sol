// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swappable price source. Prices are USD with 18 decimals.
interface IPriceOracle {
    /// @return ok      false if the price is unusable (stale, non-positive, sequencer down, feed reverted)
    /// @return price   USD price, 18 decimals
    /// @return updatedAt timestamp of the underlying observation
    function tryGetPrice(address asset) external view returns (bool ok, uint256 price, uint256 updatedAt);
}

interface IMarketClock {
    function isOpen(uint256 ts) external view returns (bool);

    /// @notice Unique id of the hourly sampling slot containing `ts` (only meaningful while open).
    function slotId(uint256 ts) external view returns (uint256);

    /// @notice Number of sampling periods between two open timestamps, or type(uint256).max if the gap
    ///         exceeds the clock's maximum lookback (the sampler then re-bases instead of recording a return).
    function periodsBetween(uint256 fromTs, uint256 toTs) external view returns (uint256);
}

interface IVolIndex {
    struct Round {
        uint64 timestamp;
        uint64 cumPeriods;
        uint128 qvix; // annualized vol in vol points, 18 decimals (25e18 == 25.0)
        uint256 cumSumSq; // cumulative sum of squared basket log-returns (18 decimals)
    }

    function latestRoundId() external view returns (uint256);

    function getRound(uint256 roundId) external view returns (Round memory);

    function latestIndex() external view returns (uint256 qvix, uint256 timestamp);

    function isReady() external view returns (bool);

    function periodsPerYear() external view returns (uint256);

    /// @notice Average QVIX of the `n` rounds ending at `hintRoundId`, where `hintRoundId` must be the last
    ///         round with timestamp <= `cutoff`. Reverts if the hint is wrong.
    function averageIndexAt(uint256 cutoff, uint256 hintRoundId, uint256 n) external view returns (uint256);

    /// @notice Verifies `hintRoundId` is the last round with timestamp <= `cutoff`.
    function isLastRoundBefore(uint256 cutoff, uint256 hintRoundId) external view returns (bool);
}

interface ICompliance {
    function isAllowed(address account) external view returns (bool);
}

interface IFeeDiscount {
    /// @return discount in basis points (0..10000) applied to trading fees
    function feeDiscountBps(address account) external view returns (uint256);
}

interface IFuturesMarketView {
    /// @notice Aggregate unrealized PnL of all open trader positions, USD 18 decimals (positive = traders up).
    function aggregateTraderPnl() external view returns (int256);

    /// @notice Notional (USD 18 decimals) the vault must keep in reserve for this market.
    function requiredReserve() external view returns (uint256);
}

interface IMarginAccount {
    function collateral() external view returns (address);

    function marketCount() external view returns (uint256);

    function marketAt(uint256 i) external view returns (address);

    function isMarket(address market) external view returns (bool);

    function lock(address user, uint256 amount) external;

    function unlock(address user, uint256 amount) external;

    function payFromLocked(address to, uint256 amount) external;

    function pullProfit(uint256 amount) external returns (uint256 paid);

    function coverBadDebt(uint256 amount) external returns (uint256 paid);

    function profitCapacity() external view returns (uint256);
}

interface ILPVault {
    function payProfit(uint256 amount) external returns (uint256 paid);

    function totalAssets() external view returns (uint256);
}

interface IInsuranceFund {
    function cover(address to, uint256 amount) external returns (uint256 paid);
}

interface IFeeCollector {
    function feeDiscountBps(address account) external view returns (uint256);
}

interface IProjectTokenHooks {
    function isActive() external view returns (bool);

    function totalStaked() external view returns (uint256);

    function notifyReward(uint256 amount) external;

    function feeDiscountBps(address account) external view returns (uint256);
}
