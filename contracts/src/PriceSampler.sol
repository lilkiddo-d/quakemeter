// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SD59x18, sd} from "@prb/math/SD59x18.sol";
import {ln} from "@prb/math/sd59x18/Math.sol";

/// @title PriceSampler
/// @notice Fixed-size ring buffers of sampled prices (per basket asset) and of equal-weight basket log-returns.
///         Running sums of squared returns and of elapsed sampling periods are kept exactly (integer add /
///         subtract of the stored values) so the index is O(1) per sample with no loops over the window.
///         Only the VolIndex (SAMPLER_ROLE) can write.
contract PriceSampler is AccessControl {
    bytes32 public constant SAMPLER_ROLE = keccak256("SAMPLER_ROLE");
    uint256 public constant MAX_ASSETS = 16;
    uint256 internal constant WAD = 1e18;

    struct ReturnSample {
        int128 logReturn; // basket log-return, 18 decimals
        uint64 periods; // sampling periods spanned by this return (>= 1)
        uint64 timestamp;
    }

    address[] internal _assets;
    uint256 public immutable windowSize; // number of returns in the window
    uint256 public immutable maxAbsLogReturn; // winsorization bound per return (18 decimals)
    uint256 public immutable minQuorum; // min valid assets for a sample

    // --- per-asset price rings (capacity windowSize + 1)
    mapping(uint256 assetIdx => mapping(uint256 slot => uint256)) internal _priceRing;
    mapping(uint256 slot => uint64) internal _priceTs;
    uint256 public priceHead; // next write position
    uint256 public priceCount;
    uint256[] public lastPrice; // last valid price per asset (0 = never)

    // --- return ring (capacity windowSize)
    mapping(uint256 slot => ReturnSample) internal _returns;
    uint256 public returnHead;
    uint256 public returnCount;
    uint256 public sumSq; // sum of squared log-returns in window (18 decimals)
    uint256 public sumPeriods; // sum of periods in window

    event PricesRecorded(uint256 indexed slot, uint64 timestamp, uint256 validAssets);
    event ReturnRecorded(int256 logReturn, uint256 periods, bool clamped, uint256 sumSq, uint256 sumPeriods);
    event GapRebased(uint64 timestamp);

    error BadConfig();
    error LengthMismatch();
    error QuorumNotMet(uint256 valid, uint256 required);

    constructor(address admin, address[] memory assets_, uint256 windowSize_, uint256 maxAbsLogReturn_, uint256 minQuorum_) {
        uint256 n = assets_.length;
        if (admin == address(0) || n == 0 || n > MAX_ASSETS) revert BadConfig();
        if (windowSize_ < 2 || windowSize_ > 10_000) revert BadConfig();
        if (maxAbsLogReturn_ == 0 || maxAbsLogReturn_ > WAD) revert BadConfig();
        if (minQuorum_ == 0 || minQuorum_ > n) revert BadConfig();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _assets = assets_;
        windowSize = windowSize_;
        maxAbsLogReturn = maxAbsLogReturn_;
        minQuorum = minQuorum_;
        lastPrice = new uint256[](n);
    }

    // ------------------------------------------------------------------ write

    /// @notice Records one sample.
    /// @param prices  USD prices (18 decimals) in asset order; ignored where !valid
    /// @param valid   per-asset validity from the oracle
    /// @param periods sampling periods since the previous sample (type(uint256).max = gap, re-base only)
    /// @return recorded true if a return was appended to the window
    /// @return logReturn the (possibly clamped) basket log-return
    function record(uint256[] calldata prices, bool[] calldata valid, uint256 periods, uint64 timestamp)
        external
        onlyRole(SAMPLER_ROLE)
        returns (bool recorded, int256 logReturn)
    {
        if (prices.length != _assets.length || valid.length != _assets.length) revert LengthMismatch();
        uint256 slot = priceHead;
        (uint256 ratioSum, uint256 ratioCount, uint256 validCount) = _ingest(prices, valid, slot);
        if (validCount < minQuorum) revert QuorumNotMet(validCount, minQuorum);

        _priceTs[slot] = timestamp;
        priceHead = (slot + 1) % (windowSize + 1);
        if (priceCount < windowSize + 1) ++priceCount;
        emit PricesRecorded(slot, timestamp, validCount);

        if (periods == type(uint256).max) {
            emit GapRebased(timestamp);
            return (false, 0);
        }
        if (ratioCount < minQuorum) return (false, 0); // first sample(s): nothing to compare against

        uint256 avgRatio = ratioSum / ratioCount;
        if (avgRatio == 0) avgRatio = 1;
        // safe: avgRatio <= ~ (2^256 / 1e18) in practice bounded by price ratios; ln domain > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        logReturn = ln(sd(int256(avgRatio))).unwrap();
        bool clamped = false;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 bound = int256(maxAbsLogReturn);
        if (logReturn > bound) {
            logReturn = bound;
            clamped = true;
        } else if (logReturn < -bound) {
            logReturn = -bound;
            clamped = true;
        }
        if (periods == 0) periods = 1;
        if (periods > type(uint64).max) periods = type(uint64).max;
        _pushReturn(logReturn, periods, timestamp);
        emit ReturnRecorded(logReturn, periods, clamped, sumSq, sumPeriods);
        return (true, logReturn);
    }

    function _ingest(uint256[] calldata prices, bool[] calldata valid, uint256 slot)
        internal
        returns (uint256 ratioSum, uint256 ratioCount, uint256 validCount)
    {
        uint256 n = prices.length;
        for (uint256 i; i < n; ++i) {
            uint256 prev = lastPrice[i];
            if (!valid[i] || prices[i] == 0) {
                // carry forward the last good price into the ring for charting continuity
                _priceRing[i][slot] = prev;
                continue;
            }
            ++validCount;
            if (prev != 0) {
                ratioSum += (prices[i] * WAD) / prev;
                ++ratioCount;
            }
            lastPrice[i] = prices[i];
            _priceRing[i][slot] = prices[i];
        }
    }

    function _pushReturn(int256 r, uint256 periods, uint64 timestamp) internal {
        uint256 slot = returnHead;
        if (returnCount == windowSize) {
            ReturnSample memory old = _returns[slot];
            sumSq -= squareWad(old.logReturn);
            sumPeriods -= old.periods;
        } else {
            ++returnCount;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        _returns[slot] = ReturnSample(int128(r), uint64(periods), timestamp);
        sumSq += squareWad(r);
        sumPeriods += periods;
        returnHead = (slot + 1) % windowSize;
    }

    // ------------------------------------------------------------------ views

    function squareWad(int256 r) public pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 a = uint256(r < 0 ? -r : r);
        return (a * a) / WAD;
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function isWindowFull() external view returns (bool) {
        return returnCount == windowSize;
    }

    /// @notice k-th most recent return (k = 0 is the latest).
    function returnAt(uint256 k) external view returns (ReturnSample memory) {
        if (k >= returnCount) revert BadConfig();
        uint256 slot = (returnHead + windowSize - 1 - k) % windowSize;
        return _returns[slot];
    }

    /// @notice k-th most recent sampled price of asset `assetIdx` and its timestamp.
    function priceAt(uint256 assetIdx, uint256 k) external view returns (uint256 price, uint64 timestamp) {
        uint256 cap = windowSize + 1;
        if (k >= priceCount || assetIdx >= _assets.length) revert BadConfig();
        uint256 slot = (priceHead + cap - 1 - k) % cap;
        return (_priceRing[assetIdx][slot], _priceTs[slot]);
    }
}
