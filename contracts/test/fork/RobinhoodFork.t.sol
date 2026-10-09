// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ConfigReader} from "../../script/ConfigReader.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {FuturesMarket} from "../../src/FuturesMarket.sol";

/// @notice Fork tests against Robinhood Chain mainnet with the real stock tokens, USDG and Chainlink feeds from
///         config/chains.json. RPC: $ROBINHOOD_RPC_URL (default: the public RPC). Block: $FORK_BLOCK (default:
///         latest — the public RPC does not serve historical state; pin a block with an archive RPC).
contract RobinhoodForkTest is Test, ConfigReader {
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address lp = makeAddr("lp");
    Config cfg;
    Deployment d;
    string[] symbols;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        // the public RPC is not an archive node: default to the latest block
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        assertEq(block.chainid, 4663, "not Robinhood Chain");
        (cfg, symbols) = _readConfig(4663);
        cfg.guardian = deployer;
        cfg.proposer = deployer;
        cfg.firstExpiryMinLead = 45 days;
        vm.startPrank(deployer);
        d = _deploy(deployer, cfg);
        vm.stopPrank();
    }

    function test_configMatchesChain() public view {
        IERC20Metadata usdg = IERC20Metadata(cfg.stablecoin);
        assertEq(usdg.symbol(), "USDG");
        assertEq(usdg.decimals(), 6);
        for (uint256 i; i < cfg.assets.length; ++i) {
            IERC20Metadata t = IERC20Metadata(cfg.assets[i]);
            assertEq(t.symbol(), symbols[i], "token symbol mismatch");
            assertEq(t.decimals(), 18);
            assertEq(IAggregatorV3(cfg.feeds[i]).decimals(), 8);
            // Chainlink description mentions the ticker (e.g. "Robinhood AAPL / USD" or "RHNVDA / USD")
            assertTrue(_contains(IAggregatorV3(cfg.feeds[i]).description(), symbols[i]), "feed/ticker mismatch");
        }
    }

    function test_realFeedsThroughAdapter() public view {
        for (uint256 i; i < cfg.assets.length; ++i) {
            (bool ok, uint256 p, uint256 t) = d.oracle.tryGetPrice(cfg.assets[i]);
            assertTrue(ok, symbols[i]);
            (, int256 ans,, uint256 upd,) = IAggregatorV3(cfg.feeds[i]).latestRoundData();
            assertEq(p, uint256(ans) * 1e10);
            assertEq(t, upd);
            assertGt(p, 1e18); // > $1
        }
    }

    function test_sampleRealPricesAtNextOpen() public {
        uint256 ts = block.timestamp;
        for (uint256 i; i < 24 * 4 && !d.clock.isOpen(ts); ++i) {
            ts += 15 minutes;
        }
        assertTrue(d.clock.isOpen(ts), "no open session within 24h of fork block");
        vm.warp(ts);
        // feeds keep their real last value; if the warp crossed the staleness bound, refresh timestamps only
        bool anyStale;
        for (uint256 i; i < cfg.assets.length; ++i) {
            (bool ok,,) = d.oracle.tryGetPrice(cfg.assets[i]);
            if (!ok) anyStale = true;
        }
        if (anyStale) _mockFreshTimestamps();
        d.volIndex.sample();
        assertEq(d.volIndex.latestRoundId(), 1);
        (uint256 p0,) = d.sampler.priceAt(0, 0);
        (, int256 ans,,,) = IAggregatorV3(cfg.feeds[0]).latestRoundData();
        assertEq(p0, uint256(ans) * 1e10);
        vm.warp(ts + 1 hours);
        if (anyStale) _mockFreshTimestamps();
        if (d.clock.isOpen(block.timestamp)) {
            d.volIndex.sample();
            assertEq(d.sampler.returnCount(), 1);
        }
    }

    function test_realUsdgDepositsAndVault() public {
        deal(cfg.stablecoin, alice, 1_000e6);
        deal(cfg.stablecoin, lp, 10_000e6);
        vm.startPrank(alice);
        IERC20Metadata(cfg.stablecoin).approve(address(d.marginAccount), 1_000e6);
        d.marginAccount.deposit(1_000e6);
        vm.stopPrank();
        assertEq(d.marginAccount.freeBalance(alice), 1_000e6);
        vm.startPrank(lp);
        IERC20Metadata(cfg.stablecoin).approve(address(d.vault), 10_000e6);
        d.vault.deposit(10_000e6, lp);
        vm.stopPrank();
        assertEq(d.vault.totalAssets(), 10_000e6);
        vm.prank(alice);
        d.marginAccount.withdraw(1_000e6);
        assertEq(IERC20Metadata(cfg.stablecoin).balanceOf(alice), 1_000e6);
    }

    function test_marketsDeployedForUpcomingExpiries() public view {
        assertEq(d.markets.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(uint256(d.markets[i].status()), uint256(FuturesMarket.Status.Pending));
            assertGt(d.markets[i].expiry(), block.timestamp + 45 days);
        }
    }

    function _mockFreshTimestamps() internal {
        for (uint256 i; i < cfg.feeds.length; ++i) {
            (uint80 r, int256 a, uint256 s,, uint80 air) = IAggregatorV3(cfg.feeds[i]).latestRoundData();
            vm.mockCall(
                cfg.feeds[i],
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(r, a, s, block.timestamp, air)
            );
        }
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool m = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }
}
