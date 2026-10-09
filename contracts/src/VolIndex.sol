// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {QuakeBase} from "./base/QuakeBase.sol";
import {PriceSampler} from "./PriceSampler.sol";
import {IPriceOracle, IMarketClock, IVolIndex} from "./interfaces/IQuake.sol";
import {UD60x18, ud} from "@prb/math/UD60x18.sol";
import {sqrt} from "@prb/math/ud60x18/Math.sol";

/// @title VolIndex — QVIX
/// @notice Samples the basket once per hourly market slot (permissionless; keepers call `sample()`), feeds the
///         PriceSampler ring buffers and publishes QVIX = 100 * sqrt(periodsPerYear * sumSq / sumPeriods), the
///         annualized realized volatility of the equal-weight basket over the trailing window (zero-mean
///         convention, as used for variance swaps). Every published value is stored as a Round with cumulative
///         accumulators so settlements and variance swaps can read history in O(1).
contract VolIndex is QuakeBase, IVolIndex {
    uint256 internal constant WAD = 1e18;
    uint256 public constant HISTORY_CAPACITY = 8192; // ~4.6 years of hourly session samples
    uint256 public constant MAX_AVG_ROUNDS = 64;

    PriceSampler public immutable sampler;
    IPriceOracle public oracle;
    IMarketClock public clock;
    uint256 public immutable override periodsPerYear;

    bool public hasSampled;
    uint256 public lastSlotId;
    uint256 public lastSampleTs;
    uint256 public override latestRoundId; // 0 = none
    uint256 public cumSumSq;
    uint256 public cumPeriods;

    mapping(uint256 => Round) internal _rounds; // roundId % HISTORY_CAPACITY

    event IndexUpdated(
        uint256 indexed roundId, uint256 timestamp, uint256 qvix, uint256 annualVariance, bool ready, int256 logReturn
    );
    event OracleSet(address indexed oracle);
    event ClockSet(address indexed clock);

    error MarketClosed();
    error AlreadySampled();
    error RoundUnavailable(uint256 roundId);
    error BadHint();

    constructor(address admin, PriceSampler sampler_, IPriceOracle oracle_, IMarketClock clock_, uint256 periodsPerYear_)
        QuakeBase(admin)
    {
        if (address(sampler_) == address(0) || address(oracle_) == address(0) || address(clock_) == address(0)) {
            revert ZeroAddress();
        }
        if (periodsPerYear_ == 0 || periodsPerYear_ > 100_000) revert InvalidParam();
        sampler = sampler_;
        oracle = oracle_;
        clock = clock_;
        periodsPerYear = periodsPerYear_;
    }

    // ------------------------------------------------------------------ admin (Timelock)

    function setOracle(IPriceOracle oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleSet(address(oracle_));
    }

    function setClock(IMarketClock clock_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(clock_) == address(0)) revert ZeroAddress();
        clock = clock_;
        lastSlotId = 0; // a new clock may use a different slot-id scheme
        emit ClockSet(address(clock_));
    }

    // ------------------------------------------------------------------ sampling

    /// @notice True if a sample can be taken now (market open and current slot not yet sampled).
    function canSample() external view returns (bool) {
        if (paused() || !clock.isOpen(block.timestamp)) return false;
        return !hasSampled || clock.slotId(block.timestamp) > lastSlotId;
    }

    /// @notice Permissionless: take this hour's sample. Reverts outside market hours or if already sampled.
    function sample() external whenNotPaused nonReentrant returns (uint256 roundId) {
        uint256 ts = block.timestamp;
        if (!clock.isOpen(ts)) revert MarketClosed();
        uint256 sid = clock.slotId(ts);
        if (hasSampled && sid <= lastSlotId) revert AlreadySampled(); // slot ids only increase

        address[] memory basket = sampler.assets();
        uint256 n = basket.length;
        uint256[] memory prices = new uint256[](n);
        bool[] memory valid = new bool[](n);
        for (uint256 i; i < n; ++i) {
            (bool ok, uint256 p, uint256 updatedAt) = oracle.tryGetPrice(basket[i]);
            valid[i] = ok && updatedAt <= ts;
            prices[i] = p;
        }
        uint256 periods = hasSampled ? clock.periodsBetween(lastSampleTs, ts) : type(uint256).max;

        // effects on own state before the (trusted) sampler write
        hasSampled = true;
        lastSlotId = sid;
        lastSampleTs = ts;

        (bool recorded, int256 r) = sampler.record(prices, valid, periods, uint64(ts));
        if (recorded) {
            cumSumSq += sampler.squareWad(r);
            cumPeriods += periods > 0 ? periods : 1;
        }

        (uint256 qvix, uint256 annualVar) = currentIndex();
        roundId = ++latestRoundId;
        _rounds[roundId % HISTORY_CAPACITY] =
            Round({timestamp: uint64(ts), cumPeriods: uint64(cumPeriods), qvix: uint128(qvix), cumSumSq: cumSumSq});
        emit IndexUpdated(roundId, ts, qvix, annualVar, sampler.isWindowFull(), r);
    }

    // ------------------------------------------------------------------ views

    /// @notice Computes QVIX from the sampler window.
    /// @return qvix annualized vol in vol points (18 decimals)
    /// @return annualVariance annualized variance as a fraction (18 decimals; 0.04e18 == 20% vol)
    function currentIndex() public view returns (uint256 qvix, uint256 annualVariance) {
        uint256 sp = sampler.sumPeriods();
        if (sp == 0) return (0, 0);
        annualVariance = (sampler.sumSq() * periodsPerYear) / sp;
        qvix = sqrt(ud(annualVariance)).unwrap() * 100;
    }

    function isReady() public view override returns (bool) {
        return sampler.isWindowFull();
    }

    function latestIndex() external view override returns (uint256 qvix, uint256 timestamp) {
        uint256 id = latestRoundId;
        if (id == 0) return (0, 0);
        Round memory r = _rounds[id % HISTORY_CAPACITY];
        return (r.qvix, r.timestamp);
    }

    function getRound(uint256 roundId) public view override returns (Round memory) {
        if (roundId == 0 || roundId > latestRoundId || latestRoundId - roundId >= HISTORY_CAPACITY) {
            revert RoundUnavailable(roundId);
        }
        return _rounds[roundId % HISTORY_CAPACITY];
    }

    /// @inheritdoc IVolIndex
    function isLastRoundBefore(uint256 cutoff, uint256 hintRoundId) public view override returns (bool) {
        Round memory r = getRound(hintRoundId);
        if (r.timestamp > cutoff) return false;
        if (hintRoundId == latestRoundId) return block.timestamp > cutoff;
        return _rounds[(hintRoundId + 1) % HISTORY_CAPACITY].timestamp > cutoff;
    }

    /// @inheritdoc IVolIndex
    function averageIndexAt(uint256 cutoff, uint256 hintRoundId, uint256 n) external view override returns (uint256) {
        if (n == 0 || n > MAX_AVG_ROUNDS) revert InvalidParam();
        if (!isLastRoundBefore(cutoff, hintRoundId)) revert BadHint();
        if (n > hintRoundId) n = hintRoundId;
        uint256 sum = 0;
        for (uint256 i; i < n; ++i) {
            sum += getRound(hintRoundId - i).qvix;
        }
        return sum / n;
    }

    /// @notice Annualized realized variance between two rounds, as a fraction (18 decimals).
    function realizedVarianceBetween(uint256 startRound, uint256 endRound) external view returns (uint256) {
        if (endRound < startRound) revert BadHint();
        Round memory a = getRound(startRound);
        Round memory b = getRound(endRound);
        if (b.cumPeriods <= a.cumPeriods) return 0;
        return ((b.cumSumSq - a.cumSumSq) * periodsPerYear) / (b.cumPeriods - a.cumPeriods);
    }
}
