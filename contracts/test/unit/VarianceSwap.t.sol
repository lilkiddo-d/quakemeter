// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {VarianceSwap, IVolIndexHistory} from "../../src/VarianceSwap.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {QuakeBase} from "../../src/base/QuakeBase.sol";
import {ICompliance} from "../../src/interfaces/IQuake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VarianceSwapTest is BaseTest {
    VarianceSwap vs;

    function setUp() public override {
        super.setUp();
        vs = d.varianceSwap;
        for (uint256 i; i < 10; ++i) {
            _sample();
        }
        usd.mint(alice, 1_000_000e6);
        usd.mint(bob, 1_000_000e6);
        vm.prank(alice);
        usd.approve(address(vs), type(uint256).max);
        vm.prank(bob);
        usd.approve(address(vs), type(uint256).max);
    }

    function _offer(bool makerLong, uint256 strikeVol) internal returns (uint256 id) {
        vm.prank(alice);
        id = vs.createOffer(makerLong, strikeVol, 1e6, 3 days, block.timestamp + 1 days);
    }

    function _hints(uint256 id) internal view returns (uint256 startHint, uint256 endHint) {
        VarianceSwap.Swap memory s = vs.getSwap(id);
        endHint = d.volIndex.latestRoundId();
        while (d.volIndex.getRound(endHint).timestamp > s.end) endHint--;
        startHint = endHint;
        while (startHint > 1 && d.volIndex.getRound(startHint - 1).timestamp >= s.start) startHint--;
    }

    function _runPast(uint256 id) internal {
        VarianceSwap.Swap memory s = vs.getSwap(id);
        while (block.timestamp <= s.end) {
            _sample();
        }
    }

    function test_collateralMath() public view {
        (uint256 l, uint256 sh) = vs.collateralFor(400e18, 1e6);
        assertEq(l, 400e6);
        assertEq(sh, 2100e6); // (6.25 - 1) * 400
        assertEq(vs.capVariance(400e18), 2500e18);
    }

    function test_createValidation() public {
        vm.startPrank(alice);
        vm.expectRevert(VarianceSwap.BadParams.selector);
        vs.createOffer(true, 0.5e18, 1e6, 3 days, block.timestamp + 1);
        vm.expectRevert(VarianceSwap.BadParams.selector);
        vs.createOffer(true, 20e18, 0, 3 days, block.timestamp + 1);
        vm.expectRevert(VarianceSwap.BadParams.selector);
        vs.createOffer(true, 20e18, 1e6, 1 hours, block.timestamp + 1);
        vm.expectRevert(VarianceSwap.BadParams.selector);
        vs.createOffer(true, 20e18, 1e6, 3 days, block.timestamp);
        vm.stopPrank();
    }

    function test_cancel() public {
        uint256 id = _offer(true, 20e18);
        vm.prank(bob);
        vm.expectRevert(VarianceSwap.NotMaker.selector);
        vs.cancelOffer(id);
        vm.prank(alice);
        vs.cancelOffer(id);
        vm.prank(alice);
        vs.claim();
        assertEq(usd.balanceOf(alice), 1_000_000e6);
        vm.prank(alice);
        vm.expectRevert(VarianceSwap.WrongStatus.selector);
        vs.cancelOffer(id);
        vm.prank(alice);
        assertEq(vs.claim(), 0);
    }

    function test_takeValidation() public {
        uint256 id = _offer(true, 20e18);
        vm.prank(alice);
        vm.expectRevert(VarianceSwap.NotAllowed.selector);
        vs.takeOffer(id);
        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        vm.expectRevert(VarianceSwap.OfferExpired.selector);
        vs.takeOffer(id);
        vm.prank(bob);
        vm.expectRevert(VarianceSwap.WrongStatus.selector);
        vs.takeOffer(999);
    }

    function test_settle_longWinsWhenStrikeLow() public {
        uint256 id = _offer(true, 1e18); // strike 1 vol: realized will be higher
        vm.prank(bob);
        vs.takeOffer(id);
        vm.expectRevert(VarianceSwap.NotMatured.selector);
        vs.settle(id, 1, 1);
        _runPast(id);
        (uint256 sh, uint256 eh) = _hints(id);
        vm.expectRevert(VarianceSwap.BadHint.selector);
        vs.settle(id, sh, eh + 1);
        vm.expectRevert(VarianceSwap.BadHint.selector);
        vs.settle(id, sh + 1, eh);
        vm.expectRevert(VarianceSwap.BadHint.selector);
        vs.settle(id, 0, eh);
        vs.settle(id, sh, eh);
        VarianceSwap.Swap memory s = vs.getSwap(id);
        assertEq(uint256(s.status), uint256(VarianceSwap.Status.Settled));
        assertGt(s.realizedVar, s.strikeVar);
        assertGt(vs.claimable(alice), s.longCollateral);
        assertEq(vs.claimable(alice) + vs.claimable(bob), s.longCollateral + s.shortCollateral);
        vm.expectRevert(VarianceSwap.WrongStatus.selector);
        vs.settle(id, sh, eh);
        vm.prank(bob);
        vs.claim();
        vm.prank(alice);
        vs.claim();
        assertEq(usd.balanceOf(address(vs)), 0);
        assertEq(vs.totalEscrowed(), 0);
        assertEq(vs.totalClaimable(), 0);
    }

    function test_settle_shortWinsWhenStrikeHigh() public {
        uint256 id = _offer(false, 80e18); // maker short at 80 vol
        vm.prank(bob);
        vs.takeOffer(id);
        _runPast(id);
        (uint256 sh, uint256 eh) = _hints(id);
        vs.settle(id, sh, eh);
        VarianceSwap.Swap memory s = vs.getSwap(id);
        assertLt(s.realizedVar, s.strikeVar);
        assertGt(vs.claimable(alice), s.shortCollateral); // maker is short
        assertLt(vs.claimable(bob), s.longCollateral);
    }

    function test_settle_capped() public {
        uint256 id = _offer(true, 1e18);
        vm.prank(bob);
        vs.takeOffer(id);
        stepBps = 2000;
        _runPast(id);
        (uint256 sh, uint256 eh) = _hints(id);
        vs.settle(id, sh, eh);
        VarianceSwap.Swap memory s = vs.getSwap(id);
        assertEq(s.realizedVar, vs.capVariance(s.strikeVar));
        assertEq(vs.claimable(bob), 0);
    }

    function test_settle_noSamplesNeutral() public {
        uint256 id = _offer(true, 20e18);
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        vs.takeOffer(id);
        VarianceSwap.Swap memory s = vs.getSwap(id);
        vm.warp(s.end + 1);
        uint256 last = d.volIndex.latestRoundId();
        vs.settle(id, last + 1, last);
        assertEq(vs.claimable(alice), s.longCollateral);
        assertEq(vs.claimable(bob), s.shortCollateral);
    }

    function test_refund() public {
        uint256 id = _offer(true, 20e18);
        vm.prank(bob);
        vs.takeOffer(id);
        VarianceSwap.Swap memory s = vs.getSwap(id);
        vm.warp(s.end + 1);
        vm.expectRevert(VarianceSwap.TooEarly.selector);
        vs.refund(id);
        vm.warp(s.end + 31 days);
        vs.refund(id);
        assertEq(vs.claimable(alice), s.longCollateral);
        vm.expectRevert(VarianceSwap.WrongStatus.selector);
        vs.refund(id);
    }

    function test_compliance() public {
        _timelock(address(d.compliance), abi.encodeCall(ComplianceRegistry.setEnabled, (true)));
        vm.prank(alice);
        vm.expectRevert(VarianceSwap.NotAllowed.selector);
        vs.createOffer(true, 20e18, 1e6, 3 days, block.timestamp + 1 days);
    }

    function test_constructor() public {
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new VarianceSwap(address(this), IERC20(address(0)), IVolIndexHistory(address(d.volIndex)));
        vm.prank(address(d.timelock));
        vs.setCompliance(ICompliance(address(d.compliance)));
    }
}
