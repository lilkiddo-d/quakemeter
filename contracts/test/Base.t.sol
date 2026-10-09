// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployCore} from "../script/DeployCore.sol";
import {MockERC20, MockAggregator} from "./mocks/Mocks.sol";
import {FuturesMarket} from "../src/FuturesMarket.sol";
import {DateTimeLib} from "../src/libraries/DateTimeLib.sol";

abstract contract BaseTest is Test, DeployCore {
    uint256 internal constant N_ASSETS = 7;

    address internal deployer = makeAddr("deployer");
    address internal guardian = makeAddr("guardian");
    address internal proposer = makeAddr("proposer");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal lp = makeAddr("lp");
    address internal bot = makeAddr("bot");

    MockERC20 internal usd;
    MockAggregator[] internal feeds;
    address[] internal assets;
    int256[] internal px;
    Deployment internal d;
    FuturesMarket internal m0;
    uint256 internal rng = 1;
    uint256 internal stepBps = 100; // max +-1% per hourly step

    /// @dev Monday 2026-10-05 09:35 EDT
    function _start() internal pure returns (uint256) {
        return DateTimeLib.daysFromCivil(2026, 10, 5) * 1 days + 13 hours + 35 minutes;
    }

    function setUp() public virtual {
        vm.warp(_start());
        usd = new MockERC20("Mock USD", "mUSD", 6);
        address[] memory feedAddrs = new address[](N_ASSETS);
        for (uint256 i; i < N_ASSETS; ++i) {
            int256 p = int256(100e8 + i * 37e8);
            MockAggregator f = new MockAggregator(8, p);
            feeds.push(f);
            px.push(p);
            assets.push(makeAddr(string.concat("asset", vm.toString(i))));
            feedAddrs[i] = address(f);
        }
        Config memory c = Config({
            stablecoin: address(usd),
            assets: assets,
            feeds: feedAddrs,
            feedMaxStaleness: 90000,
            sequencerUptimeFeed: address(0),
            guardian: guardian,
            proposer: proposer,
            treasury: treasury,
            minQuorum: 6,
            firstExpiryMinLead: 45 days
        });
        vm.startPrank(deployer);
        d = _deploy(deployer, c);
        vm.stopPrank();
        m0 = d.markets[0];
    }

    // ------------------------------------------------------------------ time & prices

    function _nextSlot() internal {
        for (uint256 i; i < 400; ++i) {
            vm.warp(block.timestamp + 1 hours);
            if (d.clock.isOpen(block.timestamp)) return;
        }
        revert("no open slot");
    }

    function _rand() internal returns (uint256) {
        return uint256(keccak256(abi.encode(rng++)));
    }

    function _movePrices() internal {
        for (uint256 i; i < N_ASSETS; ++i) {
            int256 step = int256(_rand() % (2 * stepBps + 1)) - int256(stepBps);
            px[i] = px[i] + (px[i] * step) / 10_000;
            feeds[i].set(px[i], block.timestamp);
        }
    }

    function _refreshFeeds() internal {
        for (uint256 i; i < N_ASSETS; ++i) {
            feeds[i].set(px[i], block.timestamp);
        }
    }

    function _sample() internal returns (uint256 id) {
        _nextSlot();
        _movePrices();
        id = d.volIndex.sample();
    }

    function _fillWindow() internal {
        while (!d.volIndex.isReady()) {
            _sample();
        }
    }

    function _openTrading(FuturesMarket m) internal {
        _fillWindow();
        m.openTrading();
    }

    // ------------------------------------------------------------------ money

    function _fund(address user, uint256 amount) internal {
        usd.mint(user, amount);
        vm.startPrank(user);
        usd.approve(address(d.marginAccount), amount);
        d.marginAccount.deposit(amount);
        vm.stopPrank();
    }

    function _seedVault(uint256 amount) internal {
        usd.mint(lp, amount);
        vm.startPrank(lp);
        usd.approve(address(d.vault), amount);
        d.vault.deposit(amount, lp);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ governance

    function _timelock(address target, bytes memory data) internal {
        bytes32 salt = keccak256(abi.encode(target, data, block.timestamp, rng++));
        vm.prank(proposer);
        d.timelock.schedule(target, 0, data, bytes32(0), salt, 48 hours);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(proposer);
        d.timelock.execute(target, 0, data, bytes32(0), salt);
        _refreshFeeds();
    }
}
