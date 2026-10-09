// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {FuturesMarket} from "../../src/FuturesMarket.sol";
import {console2} from "forge-std/console2.sol";

contract FlowTest is BaseTest {
    function test_deploymentWiring() public view {
        assertEq(d.markets.length, 3);
        assertTrue(d.expiries[0] > block.timestamp + 45 days);
        assertTrue(d.expiries[1] > d.expiries[0]);
        bytes32 admin = 0x00;
        assertTrue(d.volIndex.hasRole(admin, address(d.timelock)));
        assertFalse(d.volIndex.hasRole(admin, deployer));
        assertTrue(m0.hasRole(admin, address(d.timelock)));
        assertFalse(m0.hasRole(admin, deployer));
        assertTrue(m0.hasRole(m0.GUARDIAN_ROLE(), guardian));
        assertTrue(d.clock.hasRole(admin, address(d.timelock)));
        assertFalse(d.clock.hasRole(admin, deployer));
        assertFalse(d.oracle.hasRole(admin, deployer));
        assertFalse(d.sampler.hasRole(admin, deployer));
        assertFalse(d.compliance.hasRole(admin, deployer));
        assertEq(d.timelock.getMinDelay(), 48 hours);
        assertFalse(d.tokenHooks.isActive());
    }

    function test_fullLifecycle() public {
        _seedVault(1_000_000e6);
        _openTrading(m0);
        (uint256 q,) = d.volIndex.latestIndex();
        console2.log("QVIX at open", q);
        assertGt(q, 5e18);
        assertLt(q, 80e18);

        _fund(alice, 10_000e6);
        _fund(bob, 10_000e6);
        vm.prank(alice);
        uint256 a = m0.openPosition(true, 1000e18, 5_000e6, 0);
        vm.prank(bob);
        uint256 b = m0.openPosition(false, 500e18, 5_000e6, 0);

        // run index until expiry
        while (block.timestamp < m0.expiry()) {
            _sample();
        }
        uint256 hint = d.volIndex.latestRoundId();
        while (true) {
            if (d.volIndex.getRound(hint).timestamp <= m0.expiry()) break;
            hint--;
        }
        m0.settle(hint);
        assertEq(uint256(m0.status()), uint256(FuturesMarket.Status.Settled));
        m0.settlePosition(a);
        m0.settlePosition(b);
        vm.expectRevert(FuturesMarket.AlreadySettled.selector);
        m0.settlePosition(a);
        assertEq(m0.longSize(), 0);
        assertEq(m0.shortSize(), 0);
        assertEq(d.marginAccount.lockedByMarket(address(m0)), 0);
        assertGe(usd.balanceOf(address(d.marginAccount)), d.marginAccount.totalFree() + d.marginAccount.totalLocked());
    }
}
