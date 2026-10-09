// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {DateTimeLib} from "./libraries/DateTimeLib.sol";
import {IMarketClock} from "./interfaces/IQuake.sol";

/// @title MarketClock
/// @notice US equity regular-session clock (09:30-16:00 America/New_York, Mon-Fri) with on-chain DST,
///         admin-maintained exchange holidays and early closes. The session is split into hourly sampling
///         slots: slot k covers [09:30 + k h, 10:30 + k h), so a full day has 7 slots (the last is 30 min).
contract MarketClock is AccessControl, IMarketClock {
    bytes32 public constant CALENDAR_ROLE = keccak256("CALENDAR_ROLE");

    uint256 public constant OPEN_MINUTE = 570; // 09:30
    uint256 public constant DEFAULT_CLOSE_MINUTE = 960; // 16:00
    uint256 public constant SLOT_MINUTES = 60;
    uint256 public constant FULL_DAY_SLOTS = 7;
    /// @notice Gaps longer than this many calendar days make the sampler re-base instead of recording a return.
    uint256 public constant MAX_GAP_DAYS = 10;

    /// @dev local (ET) day number => closed all day
    mapping(uint256 => bool) public isHoliday;
    /// @dev local (ET) day number => early close minute-of-day (0 = regular close)
    mapping(uint256 => uint256) public earlyCloseMinute;

    event HolidaySet(uint256 indexed day, bool closed);
    event EarlyCloseSet(uint256 indexed day, uint256 closeMinute);

    error InvalidCloseMinute();
    error BadRange();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CALENDAR_ROLE, admin);
    }

    // ------------------------------------------------------------------ admin

    function setHolidays(uint256[] calldata days_, bool closed) external onlyRole(CALENDAR_ROLE) {
        uint256 len = days_.length;
        if (len > 64) revert BadRange();
        for (uint256 i; i < len; ++i) {
            isHoliday[days_[i]] = closed;
            emit HolidaySet(days_[i], closed);
        }
    }

    function setEarlyClose(uint256 day, uint256 closeMinute) external onlyRole(CALENDAR_ROLE) {
        if (closeMinute != 0 && (closeMinute <= OPEN_MINUTE || closeMinute >= DEFAULT_CLOSE_MINUTE)) {
            revert InvalidCloseMinute();
        }
        earlyCloseMinute[day] = closeMinute;
        emit EarlyCloseSet(day, closeMinute);
    }

    // ------------------------------------------------------------------ views

    /// @notice Converts a UTC timestamp to (ET day number, ET minute-of-day).
    function localDayAndMinute(uint256 ts) public pure returns (uint256 day, uint256 minute) {
        uint256 local = ts - DateTimeLib.easternOffset(ts);
        day = local / DateTimeLib.DAY;
        minute = (local % DateTimeLib.DAY) / 60;
    }

    function closeMinuteOf(uint256 day) public view returns (uint256) {
        uint256 early = earlyCloseMinute[day];
        return early == 0 ? DEFAULT_CLOSE_MINUTE : early;
    }

    /// @notice Number of sampling slots in an ET trading day (0 for weekends/holidays).
    function slotsInDay(uint256 day) public view returns (uint256) {
        uint256 wd = DateTimeLib.weekday(day);
        if (wd == 0 || wd == 6 || isHoliday[day]) return 0;
        uint256 minutes_ = closeMinuteOf(day) - OPEN_MINUTE;
        return (minutes_ + SLOT_MINUTES - 1) / SLOT_MINUTES;
    }

    function isOpen(uint256 ts) public view override returns (bool) {
        (uint256 day, uint256 minute) = localDayAndMinute(ts);
        if (slotsInDay(day) == 0) return false;
        return minute >= OPEN_MINUTE && minute < closeMinuteOf(day);
    }

    function slotOf(uint256 ts) public pure returns (uint256 day, uint256 slot) {
        uint256 minute;
        (day, minute) = localDayAndMinute(ts);
        slot = minute <= OPEN_MINUTE ? 0 : (minute - OPEN_MINUTE) / SLOT_MINUTES;
    }

    function slotId(uint256 ts) external pure override returns (uint256) {
        (uint256 day, uint256 slot) = slotOf(ts);
        return day * 16 + slot;
    }

    /// @inheritdoc IMarketClock
    function periodsBetween(uint256 fromTs, uint256 toTs) external view override returns (uint256) {
        if (toTs < fromTs) revert BadRange();
        (uint256 dayA, uint256 slotA) = slotOf(fromTs);
        (uint256 dayB, uint256 slotB) = slotOf(toTs);
        if (dayA == dayB) return slotB - slotA;
        if (dayB - dayA > MAX_GAP_DAYS) return type(uint256).max;
        uint256 slotsA = slotsInDay(dayA);
        // remaining slots of day A after the sample, the overnight boundary, then slots of day B up to the sample
        uint256 periods = (slotsA > slotA + 1 ? slotsA - 1 - slotA : 0) + slotB + 1;
        for (uint256 d = dayA + 1; d < dayB; ++d) {
            periods += slotsInDay(d);
        }
        return periods;
    }

    /// @notice Standard monthly expiry: third Friday of the month at 16:00 America/New_York, as UTC.
    function monthlyExpiry(uint256 year, uint256 month) external pure returns (uint256) {
        uint256 day = DateTimeLib.nthWeekdayOfMonth(year, month, 5, 3);
        uint256 noonUtc = day * DateTimeLib.DAY + 12 * DateTimeLib.HOUR;
        return day * DateTimeLib.DAY + 16 * DateTimeLib.HOUR + DateTimeLib.easternOffset(noonUtc);
    }
}
