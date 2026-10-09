// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BaseTest} from "../Base.t.sol";
import {FuturesMarket} from "../../src/FuturesMarket.sol";
import {MockERC20, MockAggregator} from "../mocks/Mocks.sol";
import {DeployCore} from "../../script/DeployCore.sol";

contract Handler is Test {
    // NOTE: helpers above the actions are view-only; every external non-view function is a fuzzed action
    FuturesMarket public m;
    DeployCore.Deployment internal d;
    MockERC20 public usd;
    MockAggregator[] internal feeds;
    int256[] internal px;
    address[] public users;
    address public bot = makeAddr("inv-bot");
    address public lp;

    uint256[] public ids;
    mapping(uint256 => uint256) public settleCount;
    uint256 public settleCalls;
    uint256 public liquidations;
    uint256 internal nonce;
    uint256 public calls;
    uint256 public openAttempts;
    bytes4 public lastOpenError;
    bool public forceSettle; // smoke test only

    modifier counted() {
        calls++;
        _;
    }

    function setForceSettle(bool f) external {
        forceSettle = f;
    }

    constructor(
        DeployCore.Deployment memory d_,
        FuturesMarket m_,
        MockERC20 usd_,
        MockAggregator[] memory feeds_,
        int256[] memory px_,
        address[] memory users_,
        address lp_
    ) {
        d = d_;
        m = m_;
        usd = usd_;
        for (uint256 i; i < feeds_.length; ++i) {
            feeds.push(feeds_[i]);
            px.push(px_[i]);
        }
        users = users_;
        lp = lp_;
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }

    function _user(uint256 s) internal view returns (address) {
        return users[s % users.length];
    }

    function _refresh(uint256 seed) internal {
        for (uint256 i; i < feeds.length; ++i) {
            int256 step = int256(uint256(keccak256(abi.encode(seed, i, nonce++))) % 401) - 200;
            px[i] = px[i] + (px[i] * step) / 10_000;
            feeds[i].set(px[i], block.timestamp);
        }
    }

    // ------------------------------------------------------------------ actions

    function open(uint256 userSeed, bool isLong, uint256 size, uint256 leverageBps) external counted {
        if (m.status() != FuturesMarket.Status.Trading || block.timestamp >= m.expiry()) return;
        address u = _user(userSeed);
        size = bound(size, 2e18, 600e18);
        leverageBps = bound(leverageBps, 10_000, 48_000); // 1x .. 4.8x
        int256 q = m.vamm().quote(isLong ? int256(size) : -int256(size));
        uint256 notional = uint256(q < 0 ? -q : q);
        uint256 margin = (notional * 10_000 / leverageBps) / 1e12 + notional / 1e15 + 1;
        if (d.marginAccount.freeBalance(u) < margin) return;
        openAttempts++;
        vm.prank(u);
        try m.openPosition(isLong, size, margin, 0) returns (uint256 id) {
            ids.push(id);
        } catch (bytes memory reason) {
            lastOpenError = bytes4(reason);
        }
    }

    function close(uint256 idSeed, uint256 fractionBps) external counted {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        FuturesMarket.Position memory p = m.getPosition(id);
        if (p.settled || p.size == 0) return;
        uint256 abs = uint256(p.size < 0 ? -p.size : p.size);
        uint256 sz = (abs * bound(fractionBps, 1, 10_000)) / 10_000;
        if (sz == 0) sz = abs;
        vm.prank(p.owner);
        try m.closePosition(id, sz, 0) {} catch {}
    }

    function addMargin(uint256 idSeed, uint256 amount) external counted {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        FuturesMarket.Position memory p = m.getPosition(id);
        if (p.settled || p.size == 0) return;
        amount = bound(amount, 1, 500e6);
        if (d.marginAccount.freeBalance(p.owner) < amount) return;
        vm.prank(p.owner);
        try m.addMargin(id, amount) {} catch {}
    }

    function liquidate(uint256 idSeed) external counted {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        vm.prank(bot);
        try d.liquidator.liquidate(address(m), id) {
            liquidations++;
        } catch {}
    }

    function passTime(uint256 seed, uint256 hours_) external counted {
        hours_ = bound(hours_, 1, 30);
        for (uint256 i; i < hours_; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _refresh(seed);
            if (d.volIndex.canSample()) d.volIndex.sample();
        }
    }

    function settleAll(uint256 idSeed) external counted {
        // let the market live for most of the sequence before expiring it
        if (calls < 30 && !forceSettle) return;
        if (block.timestamp <= m.expiry()) {
            // jump to expiry, keep the index fresh around it
            while (block.timestamp <= m.expiry() + 1 hours) {
                vm.warp(block.timestamp + 1 hours);
                _refresh(idSeed);
                if (d.volIndex.canSample()) d.volIndex.sample();
            }
        }
        if (m.status() != FuturesMarket.Status.Settled) {
            uint256 hint = d.volIndex.latestRoundId();
            while (hint > 1 && d.volIndex.getRound(hint).timestamp > m.expiry()) hint--;
            try m.settle(hint) {} catch {}
        }
        if (m.status() != FuturesMarket.Status.Settled || ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        settleCalls++;
        try m.settlePosition(id) {
            settleCount[id]++;
        } catch {}
    }

    function lpFlow(uint256 amount, bool deposit) external counted {
        amount = bound(amount, 1e6, 100_000e6);
        vm.startPrank(lp);
        if (deposit) {
            usd.mint(lp, amount);
            usd.approve(address(d.vault), amount);
            try d.vault.deposit(amount, lp) {} catch {}
        } else {
            uint256 maxW = d.vault.maxWithdraw(lp);
            if (maxW > 0) {
                try d.vault.withdraw(amount > maxW ? maxW : amount, lp, lp) {} catch {}
            }
        }
        vm.stopPrank();
    }

    function distributeFees() external counted {
        try d.feeCollector.distribute() {} catch {}
    }
}

abstract contract ProtocolSetup is BaseTest {
    Handler internal h;

    function setUp() public override {
        super.setUp();
        FuturesMarket.Params memory p = defaultParams();
        p.baseDepth = 20_000e18;
        _timelock(address(m0), abi.encodeCall(FuturesMarket.setParams, (p)));
        _seedVault(1_000_000e6);
        usd.mint(address(d.insurance), 20_000e6);
        _openTrading(m0);
        address[] memory us = new address[](4);
        us[0] = alice;
        us[1] = bob;
        us[2] = carol;
        us[3] = makeAddr("dave");
        for (uint256 i; i < us.length; ++i) {
            _fund(us[i], 50_000e6);
        }
        MockAggregator[] memory fs = new MockAggregator[](feeds.length);
        for (uint256 i; i < feeds.length; ++i) {
            fs[i] = feeds[i];
        }
        h = new Handler(d, m0, usd, fs, px, us, lp);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](10);
        sel[0] = Handler.open.selector;
        sel[1] = Handler.open.selector; // weight opening
        sel[2] = Handler.open.selector;
        sel[3] = Handler.close.selector;
        sel[4] = Handler.addMargin.selector;
        sel[5] = Handler.liquidate.selector;
        sel[6] = Handler.passTime.selector;
        sel[7] = Handler.settleAll.selector;
        sel[8] = Handler.lpFlow.selector;
        sel[9] = Handler.distributeFees.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

}

contract ProtocolInvariantTest is ProtocolSetup {
    /// @notice Every unit of collateral in the MarginAccount is owed to a user (free) or a position (locked).
    function invariant_marginAccountExactlyBacked() public view {
        assertEq(
            usd.balanceOf(address(d.marginAccount)), d.marginAccount.totalFree() + d.marginAccount.totalLocked()
        );
        uint256 sumFree;
        for (uint256 i; i < h.usersLength(); ++i) {
            sumFree += d.marginAccount.freeBalance(h.users(i));
        }
        sumFree += d.marginAccount.freeBalance(h.bot());
        assertEq(sumFree, d.marginAccount.totalFree());
    }

    /// @notice Locked margin equals the margin of open (unsettled) positions; aggregates match positions.
    function invariant_positionAccounting() public view {
        uint256 sumMargin;
        uint256 longs;
        uint256 shorts;
        for (uint256 i; i < h.idsLength(); ++i) {
            FuturesMarket.Position memory p = m0.getPosition(h.ids(i));
            if (p.settled) {
                assertEq(p.margin, 0);
                continue;
            }
            sumMargin += p.margin;
            if (p.size > 0) longs += uint256(p.size);
            else shorts += uint256(-p.size);
        }
        assertEq(d.marginAccount.lockedByMarket(address(m0)), sumMargin);
        assertEq(m0.longSize(), longs);
        assertEq(m0.shortSize(), shorts);
    }

    /// @notice LP vault solvency: vault + insurance can always pay all open trader profit.
    function invariant_vaultSolvent() public view {
        int256 pnl = m0.aggregateTraderPnl();
        uint256 owed = pnl > 0 ? uint256(pnl) / 1e12 : 0;
        assertGe(usd.balanceOf(address(d.vault)) + usd.balanceOf(address(d.insurance)), owed);
        assertLe(d.vault.totalAssets(), usd.balanceOf(address(d.vault)));
    }

    function afterInvariant() external view {
        console2.log("positions", h.idsLength(), "liquidations", h.liquidations());
        console2.log("open attempts", h.openAttempts(), "calls", h.calls());
        console2.logBytes4(h.lastOpenError());
        console2.log("settle calls", h.settleCalls(), "status", uint256(m0.status()));
    }

    /// @notice Each position settles at most once.
    function invariant_eachPositionSettlesOnce() public view {
        for (uint256 i; i < h.idsLength(); ++i) {
            assertLe(h.settleCount(h.ids(i)), 1);
        }
    }
}

contract HandlerSmokeTest is ProtocolSetup {
    function test_handlerOpens() public {
        h.open(1, true, 100e18, 20_000);
        h.open(2, false, 50e18, 30_000);
        assertEq(h.idsLength(), 2);
        h.passTime(1, 5);
        h.close(0, 5_000);
        h.liquidate(1);
        h.setForceSettle(true);
        h.settleAll(1);
        h.settleAll(2);
        assertEq(uint256(m0.status()), 2);
    }
}
