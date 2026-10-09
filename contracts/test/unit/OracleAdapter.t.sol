// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {MockAggregator} from "../mocks/Mocks.sol";

contract OracleAdapterTest is Test {
    OracleAdapter oracle;
    MockAggregator feed;
    address admin = makeAddr("admin");
    address asset = makeAddr("asset");

    function setUp() public {
        vm.warp(1_800_000_000);
        oracle = new OracleAdapter(admin);
        feed = new MockAggregator(8, 250e8);
        vm.prank(admin);
        oracle.setFeed(asset, address(feed), 3600);
    }

    function test_constructorZero() public {
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        new OracleAdapter(address(0));
    }

    function test_validPriceScaled() public view {
        (bool ok, uint256 p, uint256 t) = oracle.tryGetPrice(asset);
        assertTrue(ok);
        assertEq(p, 250e18);
        assertEq(t, block.timestamp);
    }

    function test_unknownAsset() public view {
        (bool ok,,) = oracle.tryGetPrice(address(1));
        assertFalse(ok);
    }

    function test_stale() public {
        vm.warp(block.timestamp + 3601);
        (bool ok,,) = oracle.tryGetPrice(asset);
        assertFalse(ok);
    }

    function test_futureTimestamp() public {
        feed.set(1e8, block.timestamp + 10);
        (bool ok,,) = oracle.tryGetPrice(asset);
        assertFalse(ok);
    }

    function test_nonPositive() public {
        feed.set(0, block.timestamp);
        (bool ok,,) = oracle.tryGetPrice(asset);
        assertFalse(ok);
        feed.set(-1, block.timestamp);
        (ok,,) = oracle.tryGetPrice(asset);
        assertFalse(ok);
    }

    function test_incompleteRound() public {
        feed.setRounds(5, 4);
        (bool ok,,) = oracle.tryGetPrice(asset);
        assertFalse(ok);
    }

    function test_reverting() public {
        feed.setReverts(true);
        (bool ok,,) = oracle.tryGetPrice(asset);
        assertFalse(ok);
    }

    function test_setFeed_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        oracle.setFeed(address(0), address(feed), 3600);
        vm.expectRevert(OracleAdapter.InvalidStaleness.selector);
        oracle.setFeed(asset, address(feed), 10);
        vm.expectRevert(OracleAdapter.InvalidStaleness.selector);
        oracle.setFeed(asset, address(feed), 8 days);
        MockAggregator bad = new MockAggregator(19, 1);
        vm.expectRevert(OracleAdapter.BadDecimals.selector);
        oracle.setFeed(asset, address(bad), 3600);
        vm.stopPrank();
        vm.expectRevert();
        oracle.setFeed(asset, address(feed), 3600);
    }

    function test_sequencerFeed() public {
        MockAggregator seq = new MockAggregator(0, 0);
        vm.startPrank(admin);
        vm.expectRevert(OracleAdapter.InvalidStaleness.selector);
        oracle.setSequencerUptimeFeed(address(seq), 2 days);
        oracle.setSequencerUptimeFeed(address(seq), 1 hours);
        vm.stopPrank();
        // just came up: inside grace period
        seq.setStartedAt(block.timestamp - 10);
        assertFalse(oracle.sequencerOk());
        (bool ok,,) = oracle.tryGetPrice(asset);
        assertFalse(ok);
        seq.setStartedAt(block.timestamp - 2 hours);
        assertTrue(oracle.sequencerOk());
        (ok,,) = oracle.tryGetPrice(asset);
        assertTrue(ok);
        seq.set(1, block.timestamp); // down
        assertFalse(oracle.sequencerOk());
        seq.set(0, block.timestamp);
        seq.setStartedAt(0);
        assertFalse(oracle.sequencerOk());
        seq.setReverts(true);
        assertFalse(oracle.sequencerOk());
    }
}
