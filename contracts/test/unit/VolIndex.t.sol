// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {VolIndex} from "../../src/VolIndex.sol";
import {PriceSampler} from "../../src/PriceSampler.sol";
import {IVolIndex, IPriceOracle, IMarketClock} from "../../src/interfaces/IQuake.sol";
import {MockOracle, MockClock} from "../mocks/Mocks.sol";
import {QuakeBase} from "../../src/base/QuakeBase.sol";

contract VolIndexTest is BaseTest {
    function test_firstSampleInitializesOnly() public {
        _nextSlot();
        _refreshFeeds();
        assertTrue(d.volIndex.canSample());
        uint256 id = d.volIndex.sample();
        assertEq(id, 1);
        assertEq(d.sampler.returnCount(), 0);
        (uint256 q, uint256 t) = d.volIndex.latestIndex();
        assertEq(q, 0);
        assertEq(t, block.timestamp);
        assertFalse(d.volIndex.canSample()); // same slot
        vm.expectRevert(VolIndex.AlreadySampled.selector);
        d.volIndex.sample();
    }

    function test_marketClosed() public {
        vm.warp(_start() + 5 days); // Saturday
        assertFalse(d.volIndex.canSample());
        vm.expectRevert(VolIndex.MarketClosed.selector);
        d.volIndex.sample();
    }

    function test_quorumNotMet() public {
        _nextSlot();
        _refreshFeeds();
        feeds[0].setReverts(true);
        feeds[1].setReverts(true);
        vm.expectRevert(abi.encodeWithSelector(PriceSampler.QuorumNotMet.selector, 5, 6));
        d.volIndex.sample();
        // one bad asset is tolerated
        feeds[1].setReverts(false);
        d.volIndex.sample();
    }

    function test_paused() public {
        vm.prank(guardian);
        d.volIndex.pause();
        _nextSlot();
        assertFalse(d.volIndex.canSample());
        vm.expectRevert();
        d.volIndex.sample();
        vm.expectRevert(); // guardian cannot unpause
        vm.prank(guardian);
        d.volIndex.unpause();
        _timelock(address(d.volIndex), abi.encodeCall(QuakeBase.unpause, ()));
        assertFalse(d.volIndex.paused());
    }

    function test_pause_unauthorized() public {
        vm.expectRevert();
        vm.prank(alice);
        d.volIndex.pause();
    }

    function test_windowFillsAndIndexReasonable() public {
        _fillWindow();
        assertTrue(d.volIndex.isReady());
        assertEq(d.sampler.returnCount(), WINDOW);
        (uint256 q,) = d.volIndex.latestIndex();
        (uint256 cur, uint256 var_) = d.volIndex.currentIndex();
        assertEq(q, cur);
        assertGt(var_, 0);
        // window keeps rolling with constant count
        _sample();
        assertEq(d.sampler.returnCount(), WINDOW);
        assertEq(d.sampler.priceCount(), WINDOW + 1);
    }

    function test_higherMovesHigherIndex() public {
        _fillWindow();
        (uint256 calm,) = d.volIndex.latestIndex();
        stepBps = 400;
        for (uint256 i; i < WINDOW; ++i) {
            _sample();
        }
        (uint256 chaos,) = d.volIndex.latestIndex();
        assertGt(chaos, calm * 3);
    }

    function test_historyViews() public {
        for (uint256 i; i < 20; ++i) {
            _sample();
        }
        uint256 last = d.volIndex.latestRoundId();
        IVolIndex.Round memory r = d.volIndex.getRound(last);
        assertEq(r.timestamp, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(VolIndex.RoundUnavailable.selector, 0));
        d.volIndex.getRound(0);
        vm.expectRevert(abi.encodeWithSelector(VolIndex.RoundUnavailable.selector, last + 1));
        d.volIndex.getRound(last + 1);

        uint256 cutoff = d.volIndex.getRound(10).timestamp;
        assertTrue(d.volIndex.isLastRoundBefore(cutoff, 10));
        assertFalse(d.volIndex.isLastRoundBefore(cutoff, 9));
        assertFalse(d.volIndex.isLastRoundBefore(cutoff, 11));
        vm.warp(block.timestamp + 1);
        assertTrue(d.volIndex.isLastRoundBefore(block.timestamp - 1, last));

        uint256 avg = d.volIndex.averageIndexAt(cutoff, 10, 3);
        uint256 manual =
            (d.volIndex.getRound(10).qvix + d.volIndex.getRound(9).qvix + d.volIndex.getRound(8).qvix) / 3;
        assertEq(avg, manual);
        // n larger than available rounds is truncated
        uint256 c2 = d.volIndex.getRound(2).timestamp;
        assertEq(d.volIndex.averageIndexAt(c2, 2, 7), (d.volIndex.getRound(2).qvix + d.volIndex.getRound(1).qvix) / 2);
        vm.expectRevert(VolIndex.BadHint.selector);
        d.volIndex.averageIndexAt(cutoff, 9, 3);
        vm.expectRevert(QuakeBase.InvalidParam.selector);
        d.volIndex.averageIndexAt(cutoff, 10, 0);
        vm.expectRevert(QuakeBase.InvalidParam.selector);
        d.volIndex.averageIndexAt(cutoff, 10, 65);

        uint256 rv = d.volIndex.realizedVarianceBetween(5, 15);
        assertGt(rv, 0);
        assertEq(d.volIndex.realizedVarianceBetween(5, 5), 0);
        vm.expectRevert(VolIndex.BadHint.selector);
        d.volIndex.realizedVarianceBetween(6, 5);
    }

    function test_adminSetters() public {
        MockOracle o = new MockOracle();
        MockClock c = new MockClock();
        vm.expectRevert();
        d.volIndex.setOracle(IPriceOracle(address(o)));
        _timelock(address(d.volIndex), abi.encodeCall(VolIndex.setOracle, (IPriceOracle(address(o)))));
        assertEq(address(d.volIndex.oracle()), address(o));
        _timelock(address(d.volIndex), abi.encodeCall(VolIndex.setClock, (IMarketClock(address(c)))));
        assertEq(address(d.volIndex.clock()), address(c));
        vm.startPrank(address(d.timelock));
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        d.volIndex.setOracle(IPriceOracle(address(0)));
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        d.volIndex.setClock(IMarketClock(address(0)));
        vm.stopPrank();
    }

    function test_constructorValidation() public {
        IPriceOracle o = IPriceOracle(address(d.oracle));
        IMarketClock c = IMarketClock(address(d.clock));
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new VolIndex(address(this), PriceSampler(address(0)), o, c, 1764);
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new VolIndex(address(this), d.sampler, IPriceOracle(address(0)), c, 1764);
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new VolIndex(address(this), d.sampler, o, IMarketClock(address(0)), 1764);
        vm.expectRevert(QuakeBase.InvalidParam.selector);
        new VolIndex(address(this), d.sampler, o, c, 0);
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new VolIndex(address(0), d.sampler, o, c, 1764);
    }

    function test_gapRebase() public {
        for (uint256 i; i < 5; ++i) {
            _sample();
        }
        uint256 before = d.sampler.returnCount();
        vm.warp(block.timestamp + 12 days);
        _sample();
        assertEq(d.sampler.returnCount(), before); // re-based, no return
        _sample();
        assertEq(d.sampler.returnCount(), before + 1);
    }
}

contract PriceSamplerTest is BaseTest {
    PriceSampler s;
    address[] a3;

    function setUp() public override {
        super.setUp();
        a3.push(address(1));
        a3.push(address(2));
        a3.push(address(3));
        s = new PriceSampler(address(this), a3, 3, 0.1e18, 2);
        s.grantRole(s.SAMPLER_ROLE(), address(this));
    }

    function _rec(uint256 p1, uint256 p2, uint256 p3, uint256 periods) internal returns (bool, int256) {
        uint256[] memory p = new uint256[](3);
        bool[] memory v = new bool[](3);
        p[0] = p1;
        p[1] = p2;
        p[2] = p3;
        v[0] = p1 != 0;
        v[1] = p2 != 0;
        v[2] = p3 != 0;
        return s.record(p, v, periods, uint64(block.timestamp));
    }

    function test_constructorValidation() public {
        address[] memory none = new address[](0);
        vm.expectRevert(PriceSampler.BadConfig.selector);
        new PriceSampler(address(this), none, 3, 0.1e18, 1);
        vm.expectRevert(PriceSampler.BadConfig.selector);
        new PriceSampler(address(0), a3, 3, 0.1e18, 1);
        vm.expectRevert(PriceSampler.BadConfig.selector);
        new PriceSampler(address(this), a3, 1, 0.1e18, 1);
        vm.expectRevert(PriceSampler.BadConfig.selector);
        new PriceSampler(address(this), a3, 3, 0, 1);
        vm.expectRevert(PriceSampler.BadConfig.selector);
        new PriceSampler(address(this), a3, 3, 0.1e18, 4);
        address[] memory many = new address[](17);
        vm.expectRevert(PriceSampler.BadConfig.selector);
        new PriceSampler(address(this), many, 3, 0.1e18, 1);
    }

    function test_accessAndLength() public {
        uint256[] memory p = new uint256[](2);
        bool[] memory v = new bool[](2);
        vm.expectRevert(PriceSampler.LengthMismatch.selector);
        s.record(p, v, 1, 0);
        vm.prank(alice);
        vm.expectRevert();
        s.record(p, v, 1, 0);
    }

    function test_returnsClampEvictAndViews() public {
        (bool rec,) = _rec(100e18, 100e18, 100e18, type(uint256).max);
        assertFalse(rec);
        (bool rec2, int256 r) = _rec(101e18, 101e18, 101e18, 1);
        assertTrue(rec2);
        assertApproxEqAbs(r, 0.00995033e18, 1e12);
        // +50% move clamps to +0.1
        (, r) = _rec(151.5e18, 151.5e18, 151.5e18, 2);
        assertEq(r, 0.1e18);
        // crash clamps to -0.1
        (, r) = _rec(50e18, 50e18, 50e18, 0);
        assertEq(r, -0.1e18);
        assertEq(s.returnAt(0).periods, 1); // 0 periods coerced to 1
        assertTrue(s.isWindowFull());
        uint256 sumBefore = s.sumSq();
        // evicts the first (small) return
        _rec(50e18, 50e18, 50e18, 1);
        assertLt(s.sumSq(), sumBefore);
        assertEq(s.returnCount(), 3);
        assertEq(s.sumPeriods(), 2 + 1 + 1);
        (uint256 price,) = s.priceAt(0, 0);
        assertEq(price, 50e18);
        vm.expectRevert(PriceSampler.BadConfig.selector);
        s.priceAt(0, 10);
        vm.expectRevert(PriceSampler.BadConfig.selector);
        s.priceAt(7, 0);
        vm.expectRevert(PriceSampler.BadConfig.selector);
        s.returnAt(5);
        assertEq(s.assetCount(), 3);
        assertEq(s.assets().length, 3);
    }

    function test_invalidAssetCarriesForward() public {
        _rec(100e18, 100e18, 100e18, type(uint256).max);
        (bool rec,) = _rec(110e18, 0, 110e18, 1); // asset 2 stale
        assertTrue(rec);
        (uint256 p,) = s.priceAt(1, 0);
        assertEq(p, 100e18); // carried forward
        // not enough assets with a reference price: 1 valid of 3 -> quorum revert
        vm.expectRevert(abi.encodeWithSelector(PriceSampler.QuorumNotMet.selector, 1, 2));
        _rec(0, 0, 100e18, 1);
    }

    function test_firstSamplesWithoutHistory() public {
        // 2 valid assets on the first sample, then a different pair: only 1 has a reference -> no return
        _rec(100e18, 100e18, 0, 1);
        (bool rec,) = _rec(0, 100e18, 100e18, 1);
        assertFalse(rec);
    }
}
