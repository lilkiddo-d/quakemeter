// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {FuturesMarket} from "../../src/FuturesMarket.sol";
import {VAMM} from "../../src/vAMM.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {QuakeBase} from "../../src/base/QuakeBase.sol";
import {ICompliance} from "../../src/interfaces/IQuake.sol";

abstract contract FuturesBase is BaseTest {
    uint256 internal constant DEPTH = 20_000e18;

    function setUp() public virtual override {
        super.setUp();
        FuturesMarket.Params memory p = defaultParams();
        p.baseDepth = DEPTH;
        _timelock(address(m0), abi.encodeCall(FuturesMarket.setParams, (p)));
        _seedVault(1_000_000e6);
        usd.mint(address(d.insurance), 50_000e6);
        _openTrading(m0);
        _fund(alice, 100_000e6);
        _fund(bob, 100_000e6);
        _fund(carol, 100_000e6);
    }

    function _setParams(FuturesMarket.Params memory p) internal {
        _timelock(address(m0), abi.encodeCall(FuturesMarket.setParams, (p)));
    }

    function _params() internal view returns (FuturesMarket.Params memory) {
        return m0.getParams();
    }

    /// @dev pushes the vAMM mark down with `n` short trades from `who`
    function _pushDown(address who, uint256 n, uint256 size) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(who);
            m0.openPosition(false, size, 20_000e6, 0);
        }
    }

    function _pushUp(address who, uint256 n, uint256 size) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(who);
            m0.openPosition(true, size, 20_000e6, 0);
        }
    }

    /// @dev shorts the vAMM (alternating bob/carol) until `id` is liquidatable, letting the EMA catch up
    function _crashUntilLiquidatable(uint256 id) internal {
        for (uint256 i; i < 12 && !m0.isLiquidatable(id); ++i) {
            _pushDown(i % 2 == 0 ? bob : carol, 1, 600e18);
            vm.warp(block.timestamp + 20 minutes);
            _refreshFeeds();
        }
        require(m0.isLiquidatable(id), "could not make liquidatable");
    }

    function _open(address who, bool isLong, uint256 size, uint256 margin) internal returns (uint256) {
        vm.prank(who);
        return m0.openPosition(isLong, size, margin, 0);
    }
}

contract FuturesMarketTest is FuturesBase {
    function test_openLong_accounting() public {
        uint256 mark = m0.markPrice();
        uint256 freeBefore = d.marginAccount.freeBalance(alice);
        uint256 id = _open(alice, true, 500e18, 2_000e6);
        FuturesMarket.Position memory p = m0.getPosition(id);
        assertEq(p.owner, alice);
        assertEq(p.size, int256(500e18));
        assertGt(p.openNotional, (500e18 * mark) / 1e18); // paid above mark (slippage)
        uint256 fee = 2_000e6 - p.margin;
        assertApproxEqAbs(fee, (p.openNotional / 1e12) / 1000, 2);
        assertEq(usd.balanceOf(address(d.feeCollector)), fee);
        assertEq(d.marginAccount.freeBalance(alice), freeBefore - 2_000e6);
        assertEq(d.marginAccount.lockedByMarket(address(m0)), p.margin);
        assertGt(m0.markPrice(), mark);
        assertEq(m0.positionsOf(alice).length, 1);
        assertEq(m0.longSize(), 500e18);
    }

    function test_openShort_andClose_roundTripCostsFees() public {
        uint256 freeBefore = d.marginAccount.freeBalance(bob);
        uint256 id = _open(bob, false, 500e18, 2_000e6);
        assertEq(m0.shortSize(), 500e18);
        vm.prank(bob);
        m0.closePosition(id, type(uint256).max, 0);
        uint256 freeAfter = d.marginAccount.freeBalance(bob);
        assertLt(freeAfter, freeBefore); // fees + rounding
        assertGt(freeAfter, freeBefore - 20e6);
        assertTrue(m0.getPosition(id).settled);
        assertEq(m0.shortSize(), 0);
        assertEq(d.marginAccount.lockedByMarket(address(m0)), 0);
    }

    function test_open_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(FuturesMarket.ZeroSize.selector);
        m0.openPosition(true, 0, 1_000e6, 0);
        vm.expectRevert(FuturesMarket.BelowMinNotional.selector);
        m0.openPosition(true, 1e18, 1_000e6, 0);
        // 6x leverage
        vm.expectRevert(FuturesMarket.InsufficientMargin.selector);
        m0.openPosition(true, 600e18, 800e6, 0);
        vm.expectRevert(FuturesMarket.InsufficientMargin.selector);
        m0.openPosition(true, 600e18, 1, 0);
        uint256 mark = m0.markPrice();
        vm.expectRevert(FuturesMarket.SlippageExceeded.selector);
        m0.openPosition(true, 500e18, 2_000e6, mark);
        vm.expectRevert(FuturesMarket.SlippageExceeded.selector);
        m0.openPosition(false, 500e18, 2_000e6, mark);
        vm.expectRevert(VAMM.PriceImpactTooHigh.selector);
        m0.openPosition(true, 2_000e18, 20_000e6, 0);
        vm.stopPrank();
    }

    function test_maxLeverageBoundary() public {
        // just under 5x works
        uint256 q = uint256(m0.vamm().quote(int256(500e18)));
        uint256 margin = (q / 1e12) / 5 + (q / 1e12) / 1000 + 10;
        uint256 id = _open(alice, true, 500e18, margin);
        assertGt(id, 0);
    }

    function test_oiCap() public {
        FuturesMarket.Params memory p = _params();
        p.maxNetOiBps = 1; // 0.01% of $1M = $100
        _setParams(p);
        vm.expectRevert(FuturesMarket.OiCapExceeded.selector);
        _open(alice, true, 100e18, 1_000e6);
        p.maxNetOiBps = 2000;
        p.maxGrossOiBps = 1;
        _setParams(p);
        vm.expectRevert(FuturesMarket.OiCapExceeded.selector);
        _open(alice, true, 100e18, 1_000e6);
    }

    function test_close_profitPulledFromVault() public {
        uint256 id = _open(alice, true, 500e18, 2_000e6);
        _pushUp(bob, 2, 500e18);
        uint256 vaultBefore = usd.balanceOf(address(d.vault));
        uint256 freeBefore = d.marginAccount.freeBalance(alice);
        vm.prank(alice);
        m0.closePosition(id, type(uint256).max, 0);
        uint256 got = d.marginAccount.freeBalance(alice) - freeBefore;
        assertGt(got, 2_000e6);
        assertLt(usd.balanceOf(address(d.vault)), vaultBefore);
    }

    function test_partialClose_andGuards() public {
        uint256 id = _open(alice, true, 500e18, 2_000e6);
        vm.prank(bob);
        vm.expectRevert(FuturesMarket.NotOwner.selector);
        m0.closePosition(id, 100e18, 0);
        vm.startPrank(alice);
        vm.expectRevert(FuturesMarket.ZeroSize.selector);
        m0.closePosition(id, 0, 0);
        vm.expectRevert(FuturesMarket.SlippageExceeded.selector);
        m0.closePosition(id, 100e18, type(uint256).max); // selling with an impossible min price
        m0.closePosition(id, 200e18, 0);
        vm.stopPrank();
        FuturesMarket.Position memory p = m0.getPosition(id);
        assertEq(p.size, int256(300e18));
        assertFalse(p.settled);
        assertEq(m0.longSize(), 300e18);
        vm.prank(alice);
        m0.closePosition(id, 1_000e18, 0); // over-size is clamped
        assertTrue(m0.getPosition(id).settled);
        vm.prank(alice);
        vm.expectRevert(FuturesMarket.AlreadySettled.selector);
        m0.closePosition(id, 1, 0);
    }

    function test_partialClose_cannotLeaveUnhealthy() public {
        uint256 q = uint256(m0.vamm().quote(int256(500e18)));
        uint256 id = _open(alice, true, 500e18, (q / 1e12) / 5 + (q / 1e12) / 1000 + 20);
        _crashUntilLiquidatable(id);
        vm.prank(alice);
        vm.expectRevert(FuturesMarket.InsufficientMargin.selector);
        m0.closePosition(id, 10e18, 0);
    }

    function test_addRemoveMargin() public {
        uint256 id = _open(alice, true, 500e18, 2_000e6);
        uint256 m = m0.getPosition(id).margin;
        vm.startPrank(alice);
        m0.addMargin(id, 500e6);
        assertEq(m0.getPosition(id).margin, m + 500e6);
        vm.expectRevert(FuturesMarket.ZeroSize.selector);
        m0.addMargin(id, 0);
        m0.removeMargin(id, 400e6);
        vm.expectRevert(FuturesMarket.InsufficientMargin.selector);
        m0.removeMargin(id, m + 100e6);
        vm.expectRevert(FuturesMarket.InsufficientMargin.selector);
        m0.removeMargin(id, m - 100e6); // would drop below initial margin
        vm.expectRevert(FuturesMarket.InsufficientMargin.selector);
        m0.removeMargin(id, 0);
        vm.stopPrank();
    }

    function test_funding_longsPayWhenMarkAboveIndex() public {
        uint256 id = _open(alice, true, 800e18, 5_000e6);
        (uint256 index,) = d.volIndex.latestIndex();
        assertGt(m0.markPrice(), index);
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        FuturesMarket.PositionView memory v = m0.positionView(id);
        assertGt(v.fundingOwed, 0);
        // shorts receive
        uint256 sid = _open(bob, false, 100e18, 2_000e6);
        assertGt(m0.cumFunding(), 0);
        vm.warp(block.timestamp + 1 days);
        assertLt(m0.positionView(sid).fundingOwed, 0);
        uint256 marginBefore = m0.getPosition(id).margin;
        vm.prank(alice);
        m0.addMargin(id, 1e6); // no funding realization on add
        vm.prank(alice);
        m0.removeMargin(id, 1e6); // realizes funding
        assertLt(m0.getPosition(id).margin, marginBefore);
        // funding is clamped: at most maxFundingPremium per day
        int256 maxPerDay = int256((index * 1000) / 10_000);
        assertLe(m0.cumFunding(), maxPerDay * 3);
    }

    function test_liquidation_full() public {
        uint256 q = uint256(m0.vamm().quote(int256(500e18)));
        uint256 id = _open(alice, true, 500e18, (q / 1e12) / 5 + (q / 1e12) / 1000 + 20);
        assertFalse(d.liquidator.isLiquidatable(address(m0), id));
        vm.expectRevert(FuturesMarket.NotLiquidatable.selector);
        vm.prank(bot);
        d.liquidator.liquidate(address(m0), id);

        _crashUntilLiquidatable(id);
        assertTrue(m0.positionView(id).liquidatable);
        uint256 insBefore = usd.balanceOf(address(d.insurance));
        vm.prank(bot);
        uint256 reward = d.liquidator.liquidate(address(m0), id);
        assertGt(reward, 0);
        assertEq(usd.balanceOf(bot), reward);
        assertTrue(m0.getPosition(id).settled);
        assertGe(usd.balanceOf(address(d.insurance)) + 1, insBefore); // penalty in, maybe bad-debt out
        assertFalse(m0.isLiquidatable(id));
    }

    function test_liquidation_partialForLargePositions() public {
        FuturesMarket.Params memory p = _params();
        p.partialLiquidationNotional = 1_000e18;
        _setParams(p);
        uint256 q = uint256(m0.vamm().quote(int256(800e18)));
        uint256 id = _open(alice, true, 800e18, (q / 1e12) * 22 / 100);
        _crashUntilLiquidatable(id);
        vm.prank(bot);
        d.liquidator.liquidate(address(m0), id);
        FuturesMarket.Position memory after_ = m0.getPosition(id);
        assertEq(after_.size, int256(400e18));
        assertFalse(after_.settled);
    }

    function test_liquidation_badDebtCoveredByInsurance() public {
        uint256 q = uint256(m0.vamm().quote(int256(600e18)));
        uint256 id = _open(alice, true, 600e18, (q / 1e12) / 5 + (q / 1e12) / 1000 + 20);
        _pushDown(bob, 4, 800e18);
        _pushDown(carol, 3, 800e18);
        vm.warp(block.timestamp + 20 minutes);
        _refreshFeeds();
        FuturesMarket.PositionView memory v = m0.positionView(id);
        assertLt(v.equity, 0);
        uint256 insBefore = usd.balanceOf(address(d.insurance));
        vm.recordLogs();
        vm.prank(bot);
        d.liquidator.liquidate(address(m0), id);
        assertLt(usd.balanceOf(address(d.insurance)), insBefore); // insurance paid the vault
        assertTrue(m0.getPosition(id).settled);
    }

    function test_liquidateBatch_success() public {
        uint256 q = uint256(m0.vamm().quote(int256(500e18)));
        uint256 id = _open(alice, true, 500e18, (q / 1e12) / 5 + (q / 1e12) / 1000 + 20);
        _crashUntilLiquidatable(id);
        assertTrue(d.liquidator.isLiquidatable(address(m0), id));
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(bot);
        uint256 total = d.liquidator.liquidateBatch(address(m0), ids);
        assertGt(total, 0);
        assertEq(usd.balanceOf(bot), total);
    }

    function test_liquidate_onlyLiquidatorRole_andBatch() public {
        uint256 id = _open(alice, true, 500e18, 3_000e6);
        vm.expectRevert();
        m0.liquidate(id, bot);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = 999;
        vm.prank(bot);
        uint256 total = d.liquidator.liquidateBatch(address(m0), ids);
        assertEq(total, 0);
        uint256[] memory many = new uint256[](26);
        vm.expectRevert(Liquidator.BatchTooLarge.selector);
        d.liquidator.liquidateBatch(address(m0), many);
        vm.expectRevert(Liquidator.UnknownMarket.selector);
        d.liquidator.liquidate(address(0xdead), 1);
        vm.expectRevert(Liquidator.UnknownMarket.selector);
        d.liquidator.liquidateBatch(address(0xdead), ids);
        assertFalse(d.liquidator.isLiquidatable(address(0xdead), 1));
    }

    function test_views() public {
        uint256 id = _open(alice, true, 500e18, 2_000e6);
        FuturesMarket.PositionView memory v = m0.positionView(id);
        assertGt(v.entryPrice, 0);
        assertGt(v.liquidationPrice, 0);
        assertLt(v.liquidationPrice, v.entryPrice);
        // equity at the liquidation price ~= maintenance requirement
        uint256 s = 500e18;
        int256 eqAtLiq =
            int256(v.margin * 1e12) + int256((s * v.liquidationPrice) / 1e18) - int256(v.openNotional) - v.fundingOwed;
        int256 maint = int256(((s * v.liquidationPrice) / 1e18) * 1000 / 10_000);
        assertApproxEqAbs(eqAtLiq, maint, 1e15);

        uint256 sid = _open(bob, false, 300e18, 2_000e6);
        FuturesMarket.PositionView memory sv = m0.positionView(sid);
        assertGt(sv.liquidationPrice, sv.entryPrice);
        assertGt(m0.requiredReserve(), 0);
        assertEq(m0.collateralScale(), 1e12);
        assertGt(m0.emaMarkPrice(), 0);
        FuturesMarket.PositionView memory empty = m0.positionView(12345);
        assertEq(empty.size, 0);
        _pushUp(carol, 2, 500e18);
        vm.warp(block.timestamp + 20 minutes);
        assertGt(m0.aggregateTraderPnl(), -int256(1e30));
        // highly overcollateralized short has no liquidation price
        uint256 safe = _open(carol, false, 20e18, 15_000e6);
        assertGt(m0.positionView(safe).liquidationPrice, 0);
        uint256 safeLong = _open(carol, true, 20e18, 15_000e6);
        assertEq(m0.positionView(safeLong).liquidationPrice, 0);
    }

    function test_settlementFlow() public {
        uint256 a = _open(alice, true, 500e18, 3_000e6);
        uint256 b = _open(bob, false, 300e18, 3_000e6);
        vm.expectRevert(FuturesMarket.NotExpired.selector);
        m0.settle(1);
        vm.expectRevert(FuturesMarket.WrongStatus.selector);
        m0.settlePosition(a);
        while (block.timestamp < m0.expiry()) {
            _sample();
        }
        vm.expectRevert(FuturesMarket.Expired.selector);
        _open(alice, true, 100e18, 1_000e6);
        uint256 hint = d.volIndex.latestRoundId();
        while (d.volIndex.getRound(hint).timestamp > m0.expiry()) hint--;
        vm.expectRevert();
        m0.settle(hint + 1);
        m0.settle(hint);
        vm.expectRevert(FuturesMarket.AlreadySettled.selector);
        m0.settle(hint);
        vm.expectRevert(FuturesMarket.AlreadySettled.selector);
        vm.prank(address(d.timelock));
        m0.emergencySettle(1e18);
        assertGt(m0.settlementPrice(), 0);
        assertEq(m0.requiredReserve(), 0);
        uint256 before = d.marginAccount.freeBalance(alice);
        vm.prank(carol); // anyone can settle; proceeds go to the owner
        m0.settlePosition(a);
        assertGt(d.marginAccount.freeBalance(alice), before);
        m0.settlePosition(b);
        vm.expectRevert(FuturesMarket.NotOwner.selector);
        m0.settlePosition(999);
        assertEq(m0.aggregateTraderPnl(), 0);
        assertEq(m0.positionView(a).size, 0);
    }

    function test_settle_staleIndexAndEmergency() public {
        _open(alice, true, 200e18, 3_000e6);
        uint256 lastRound = d.volIndex.latestRoundId();
        vm.warp(m0.expiry() + 1);
        vm.expectRevert(FuturesMarket.StaleSettlement.selector);
        m0.settle(lastRound);
        vm.expectRevert(FuturesMarket.TooEarly.selector);
        vm.prank(address(d.timelock));
        m0.emergencySettle(20e18);
        vm.warp(m0.expiry() + 8 days);
        vm.expectRevert();
        m0.emergencySettle(20e18);
        vm.prank(address(d.timelock));
        m0.emergencySettle(1_000e18); // capped at maxSettlementPrice
        assertEq(m0.settlementPrice(), 400e18);
    }

    function test_openTrading_reverts() public {
        vm.expectRevert(FuturesMarket.WrongStatus.selector);
        m0.openTrading();
    }

    function test_compliance_gate() public {
        _timelock(address(d.compliance), abi.encodeCall(ComplianceRegistry.setEnabled, (true)));
        vm.expectRevert(FuturesMarket.NotAllowed.selector);
        _open(alice, true, 100e18, 1_000e6);
        address[] memory list = new address[](1);
        list[0] = alice;
        _timelock(address(d.compliance), abi.encodeCall(ComplianceRegistry.setAllowlisted, (list, true)));
        _open(alice, true, 100e18, 1_000e6);
        _timelock(address(m0), abi.encodeCall(FuturesMarket.setCompliance, (ICompliance(address(0)))));
        _open(bob, true, 100e18, 1_000e6);
    }

    function test_paused_blocksTrading() public {
        vm.prank(guardian);
        m0.pause();
        vm.expectRevert();
        _open(alice, true, 100e18, 1_000e6);
    }

    function test_setParams_validation() public {
        FuturesMarket.Params memory p = _params();
        p.maintenanceMarginBps = p.initialMarginBps;
        vm.prank(address(d.timelock));
        vm.expectRevert(QuakeBase.InvalidParam.selector);
        m0.setParams(p);
    }
}

contract FuturesMarketPendingTest is BaseTest {
    function test_notReady() public {
        vm.expectRevert(FuturesMarket.NotReady.selector);
        m0.openTrading();
        vm.expectRevert(FuturesMarket.WrongStatus.selector);
        m0.openPosition(true, 1e18, 1e6, 0);
    }

    function test_tooCloseToExpiry() public {
        vm.warp(m0.expiry() - 1 hours);
        vm.expectRevert(FuturesMarket.Expired.selector);
        m0.openTrading();
    }

    function test_constructorValidation() public {
        FuturesMarket.Deps memory deps = FuturesMarket.Deps({
            volIndex: m0.volIndex(),
            marginAccount: m0.marginAccount(),
            vault: m0.vault(),
            insurance: m0.insurance(),
            feeCollector: m0.feeCollector(),
            compliance: ICompliance(address(0))
        });
        vm.expectRevert(QuakeBase.InvalidParam.selector);
        new FuturesMarket(address(this), block.timestamp, deps, defaultParams(), defaultVammCfg());
        deps.insurance = address(0);
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new FuturesMarket(address(this), block.timestamp + 1 days, deps, defaultParams(), defaultVammCfg());
    }

    function test_settleWithoutTrading() public {
        _fillWindow();
        while (block.timestamp < m0.expiry()) {
            _sample();
        }
        uint256 hint = d.volIndex.latestRoundId();
        while (d.volIndex.getRound(hint).timestamp > m0.expiry()) hint--;
        m0.settle(hint);
        assertGt(m0.settlementPrice(), 0);
        assertEq(m0.aggregateTraderPnl(), 0);
    }
}

contract VAMMTest is BaseTest {
    VAMM amm;

    function setUp() public override {
        super.setUp();
        amm = new VAMM(address(this), 900, 1000, 1e18, 500e18);
    }

    function test_constructorValidation() public {
        vm.expectRevert(VAMM.BadParam.selector);
        new VAMM(address(0), 900, 1000, 1e18, 500e18);
        vm.expectRevert(VAMM.BadParam.selector);
        new VAMM(address(this), 900, 6000, 1e18, 500e18);
        vm.expectRevert(VAMM.BadParam.selector);
        new VAMM(address(this), 900, 1000, 5e18, 5e18);
    }

    function test_lifecycle() public {
        assertFalse(amm.initialized());
        assertEq(amm.markPrice(), 0);
        assertEq(amm.currentEma(), 0);
        vm.expectRevert(VAMM.NotInitialized.selector);
        amm.swap(1e18, true);
        vm.expectRevert(VAMM.NotInitialized.selector);
        amm.quote(1e18);
        vm.expectRevert(VAMM.BadParam.selector);
        amm.initialize(0.5e18, 1000e18);
        vm.expectRevert(VAMM.BadParam.selector);
        amm.initialize(20e18, 0.5e18);
        amm.initialize(20e18, 10_000e18);
        vm.expectRevert(VAMM.AlreadyInitialized.selector);
        amm.initialize(20e18, 10_000e18);
        assertEq(amm.markPrice(), 20e18);
        assertEq(amm.quote(0), 0);

        int256 cost = amm.swap(100e18, true);
        assertGt(cost, 2000e18);
        int256 back = amm.swap(-100e18, true);
        assertLt(-back, cost); // round trip never profits
        assertLe(amm.markPrice(), 20e18 + 1e9);

        vm.expectRevert(VAMM.InsufficientLiquidity.selector);
        amm.swap(10_000e18, false);
        vm.expectRevert(VAMM.PriceImpactTooHigh.selector);
        amm.swap(1_000e18, true);
        amm.swap(1_000e18, false); // liquidations skip impact check
        vm.prank(alice);
        vm.expectRevert(VAMM.OnlyMarket.selector);
        amm.swap(1e18, true);
    }

    function test_priceBounds() public {
        amm.initialize(1.05e18, 10_000e18);
        vm.expectRevert(VAMM.PriceOutOfBounds.selector);
        amm.swap(-500e18, false);
    }

    function test_emaTracksSlowly() public {
        amm.initialize(20e18, 10_000e18);
        amm.swap(300e18, true);
        uint256 spot = amm.markPrice();
        assertEq(amm.currentEma(), 20e18);
        vm.warp(block.timestamp + 450);
        uint256 half = amm.currentEma();
        assertApproxEqRel(half, (20e18 + spot) / 2, 1e15);
        amm.swap(-300e18, true);
        vm.warp(block.timestamp + 10_000);
        assertEq(amm.currentEma(), amm.markPrice());
    }

    function testFuzz_roundTripNeverProfits(uint256 size, bool longFirst) public {
        amm.initialize(20e18, 10_000e18);
        size = bound(size, 1e15, 400e18);
        int256 s = longFirst ? int256(size) : -int256(size);
        int256 q1 = amm.swap(s, false);
        int256 q2 = amm.swap(-s, false);
        assertGe(q1 + q2, 0); // trader net quote paid >= 0
    }
}
