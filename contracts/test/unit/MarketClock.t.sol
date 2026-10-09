// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {DateTimeLib} from "../../src/libraries/DateTimeLib.sol";

contract MarketClockTest is Test {
    MarketClock clock;
    address admin = makeAddr("admin");

    function setUp() public {
        clock = new MarketClock(admin);
    }

    function _ts(uint256 y, uint256 m, uint256 d, uint256 hh, uint256 mm) internal pure returns (uint256) {
        return DateTimeLib.daysFromCivil(y, m, d) * 1 days + hh * 1 hours + mm * 1 minutes;
    }

    function test_civilRoundTrip() public pure {
        uint256 day = DateTimeLib.daysFromCivil(2026, 10, 8);
        (uint256 y, uint256 m, uint256 d) = DateTimeLib.civilFromDays(day);
        assertEq(y, 2026);
        assertEq(m, 10);
        assertEq(d, 8);
        assertEq(DateTimeLib.weekday(day), 4); // Thursday
        (y, m, d) = DateTimeLib.civilFromDays(DateTimeLib.daysFromCivil(2028, 2, 29));
        assertEq(y * 10000 + m * 100 + d, 20280229);
        (y, m, d) = DateTimeLib.civilFromDays(DateTimeLib.daysFromCivil(2027, 1, 15));
        assertEq(y * 10000 + m * 100 + d, 20270115);
    }

    function testFuzz_civilRoundTrip(uint256 day) public pure {
        day = bound(day, 0, 200_000);
        (uint256 y, uint256 m, uint256 d) = DateTimeLib.civilFromDays(day);
        assertEq(DateTimeLib.daysFromCivil(y, m, d), day);
    }

    function test_dstBoundaries2026() public view {
        // DST starts Sun 2026-03-08 07:00 UTC, ends Sun 2026-11-01 06:00 UTC
        assertFalse(DateTimeLib.isUsEasternDst(_ts(2026, 3, 8, 6, 59)));
        assertTrue(DateTimeLib.isUsEasternDst(_ts(2026, 3, 8, 7, 0)));
        assertTrue(DateTimeLib.isUsEasternDst(_ts(2026, 11, 1, 5, 59)));
        assertFalse(DateTimeLib.isUsEasternDst(_ts(2026, 11, 1, 6, 0)));
        // Fri 2026-03-06 (EST): opens 14:30 UTC
        assertFalse(clock.isOpen(_ts(2026, 3, 6, 14, 29)));
        assertTrue(clock.isOpen(_ts(2026, 3, 6, 14, 30)));
        assertTrue(clock.isOpen(_ts(2026, 3, 6, 20, 59)));
        assertFalse(clock.isOpen(_ts(2026, 3, 6, 21, 0)));
        // Mon 2026-03-09 (EDT): opens 13:30 UTC
        assertTrue(clock.isOpen(_ts(2026, 3, 9, 13, 30)));
        assertFalse(clock.isOpen(_ts(2026, 3, 9, 20, 0)));
    }

    function test_weekendClosed() public view {
        assertFalse(clock.isOpen(_ts(2026, 10, 10, 15, 0))); // Saturday
        assertFalse(clock.isOpen(_ts(2026, 10, 11, 15, 0))); // Sunday
        assertEq(clock.slotsInDay(DateTimeLib.daysFromCivil(2026, 10, 10)), 0);
        assertEq(clock.slotsInDay(DateTimeLib.daysFromCivil(2026, 10, 12)), 7);
    }

    function test_holidaysAndEarlyClose() public {
        uint256 thanksgiving = DateTimeLib.daysFromCivil(2026, 11, 26);
        uint256 blackFriday = DateTimeLib.daysFromCivil(2026, 11, 27);
        uint256[] memory days_ = new uint256[](1);
        days_[0] = thanksgiving;
        vm.startPrank(admin);
        clock.setHolidays(days_, true);
        clock.setEarlyClose(blackFriday, 780);
        vm.stopPrank();
        assertFalse(clock.isOpen(_ts(2026, 11, 26, 16, 0)));
        assertTrue(clock.isOpen(_ts(2026, 11, 27, 17, 59))); // 12:59 EST
        assertFalse(clock.isOpen(_ts(2026, 11, 27, 18, 0))); // 13:00 EST
        assertEq(clock.slotsInDay(blackFriday), 4);
        assertEq(clock.closeMinuteOf(blackFriday), 780);
        // Wed slot 6 -> Fri slot 0 skips the holiday: 0 + 1 = 1 period
        assertEq(clock.periodsBetween(_ts(2026, 11, 25, 20, 45), _ts(2026, 11, 27, 14, 35)), 1);
        // reset
        vm.prank(admin);
        clock.setEarlyClose(blackFriday, 0);
        assertEq(clock.slotsInDay(blackFriday), 7);
    }

    function test_setters_revert() public {
        vm.startPrank(admin);
        vm.expectRevert(MarketClock.InvalidCloseMinute.selector);
        clock.setEarlyClose(1, 500);
        vm.expectRevert(MarketClock.InvalidCloseMinute.selector);
        clock.setEarlyClose(1, 960);
        uint256[] memory many = new uint256[](65);
        vm.expectRevert(MarketClock.BadRange.selector);
        clock.setHolidays(many, true);
        vm.stopPrank();
        vm.expectRevert();
        clock.setEarlyClose(1, 780);
    }

    function test_slotsAndPeriods() public view {
        uint256 mon935 = _ts(2026, 10, 12, 13, 35); // 09:35 EDT, slot 0
        uint256 mon1535 = _ts(2026, 10, 12, 19, 35); // 15:35 EDT, slot 6
        (, uint256 s0) = clock.slotOf(mon935);
        (, uint256 s6) = clock.slotOf(mon1535);
        assertEq(s0, 0);
        assertEq(s6, 6);
        assertEq(clock.periodsBetween(mon935, mon1535), 6);
        assertEq(clock.periodsBetween(mon935, mon935), 0);
        // Mon slot 6 -> Tue slot 0 : 1 (overnight)
        assertEq(clock.periodsBetween(mon1535, mon935 + 1 days), 1);
        // Mon slot 3 -> Tue slot 2 : (6-3) + 2 + 1 = 6
        assertEq(clock.periodsBetween(mon935 + 3 hours, mon935 + 1 days + 2 hours), 6);
        // Fri slot 6 -> Mon slot 0 : 1
        assertEq(clock.periodsBetween(_ts(2026, 10, 9, 19, 35), mon935), 1);
        // Mon slot 0 -> Wed slot 0 : 6 + 7 + 1 = 14
        assertEq(clock.periodsBetween(mon935, mon935 + 2 days), 14);
        // gap too large
        assertEq(clock.periodsBetween(mon935, mon935 + 11 days), type(uint256).max);
        assertTrue(clock.slotId(mon935) != clock.slotId(mon935 + 1 hours));
        assertEq(clock.slotId(mon935), clock.slotId(mon935 + 20 minutes));
        // before the open the slot is clamped to 0
        (, uint256 pre) = clock.slotOf(_ts(2026, 10, 12, 12, 0));
        assertEq(pre, 0);
    }

    function test_periodsBetween_revertsOnReverse() public {
        vm.expectRevert(MarketClock.BadRange.selector);
        clock.periodsBetween(2, 1);
    }

    function test_monthlyExpiry() public view {
        // third Friday Nov 2026 = Nov 20, 16:00 EST = 21:00 UTC
        assertEq(clock.monthlyExpiry(2026, 11), _ts(2026, 11, 20, 21, 0));
        // third Friday Jul 2026 = Jul 17, 16:00 EDT = 20:00 UTC
        assertEq(clock.monthlyExpiry(2026, 7), _ts(2026, 7, 17, 20, 0));
    }
}
