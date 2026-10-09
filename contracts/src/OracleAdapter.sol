// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IPriceOracle} from "./interfaces/IQuake.sol";

/// @title OracleAdapter
/// @notice Chainlink implementation of IPriceOracle. Swappable: VolIndex holds an IPriceOracle reference
///         that the Timelock can replace (e.g. with a Data Streams adapter) without touching other contracts.
///         Checks: positive answer, complete round, staleness per feed, optional L2 sequencer uptime feed.
contract OracleAdapter is AccessControl, IPriceOracle {
    struct FeedConfig {
        IAggregatorV3 feed;
        uint32 maxStaleness; // seconds
        uint8 decimals;
    }

    uint256 public constant MIN_STALENESS = 60;
    uint256 public constant MAX_STALENESS = 7 days;

    mapping(address asset => FeedConfig) public feeds;

    /// @notice Chainlink L2 sequencer uptime feed. address(0) = not available on this chain (check skipped).
    IAggregatorV3 public sequencerUptimeFeed;
    uint256 public sequencerGracePeriod = 1 hours;

    event FeedSet(address indexed asset, address indexed feed, uint256 maxStaleness, uint8 decimals);
    event SequencerFeedSet(address indexed feed, uint256 gracePeriod);

    error InvalidStaleness();
    error ZeroAddress();
    error BadDecimals();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setFeed(address asset, address feed, uint32 maxStaleness) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0) || feed == address(0)) revert ZeroAddress();
        if (maxStaleness < MIN_STALENESS || maxStaleness > MAX_STALENESS) revert InvalidStaleness();
        uint8 dec = IAggregatorV3(feed).decimals();
        if (dec > 18) revert BadDecimals();
        feeds[asset] = FeedConfig(IAggregatorV3(feed), maxStaleness, dec);
        emit FeedSet(asset, feed, maxStaleness, dec);
    }

    function setSequencerUptimeFeed(address feed, uint256 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gracePeriod > 1 days) revert InvalidStaleness();
        sequencerUptimeFeed = IAggregatorV3(feed);
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    /// @notice True if there is no sequencer feed configured or the sequencer has been up past the grace period.
    function sequencerOk() public view returns (bool) {
        IAggregatorV3 seq = sequencerUptimeFeed;
        if (address(seq) == address(0)) return true;
        try seq.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            // answer == 0: sequencer up; 1: down
            if (answer != 0 || answeredInRound < roundId || updatedAt < startedAt) return false;
            if (startedAt == 0 || block.timestamp - startedAt <= sequencerGracePeriod) return false;
            return true;
        } catch {
            return false;
        }
    }

    /// @inheritdoc IPriceOracle
    function tryGetPrice(address asset) external view override returns (bool ok, uint256 price, uint256 updatedAt) {
        FeedConfig memory cfg = feeds[asset];
        if (address(cfg.feed) == address(0)) return (false, 0, 0);
        if (!sequencerOk()) return (false, 0, 0);
        try cfg.feed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updated, uint80 answeredInRound
        ) {
            if (answer <= 0 || updated == 0 || startedAt > updated || answeredInRound < roundId) return (false, 0, 0);
            if (updated > block.timestamp || block.timestamp - updated > cfg.maxStaleness) return (false, 0, 0);
            // casting is safe: answer > 0 checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            price = uint256(answer) * 10 ** (18 - cfg.decimals);
            return (true, price, updated);
        } catch {
            return (false, 0, 0);
        }
    }
}
