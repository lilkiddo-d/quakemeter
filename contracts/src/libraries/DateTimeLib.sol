// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DateTimeLib
/// @notice Gregorian calendar helpers (Howard Hinnant's civil-from-days algorithms) and US Eastern DST rules.
// The calendar algorithms below rely on intentional integer floor division (that is the algorithm, not a
// precision bug), so Slither's divide-before-multiply detector is disabled for this file only.
// slither-disable-start divide-before-multiply
library DateTimeLib {
    uint256 internal constant DAY = 86400;
    uint256 internal constant HOUR = 3600;

    /// @notice Converts days since 1970-01-01 to a (year, month, day) civil date.
    function civilFromDays(uint256 z) internal pure returns (uint256 y, uint256 m, uint256 d) {
        unchecked {
            z += 719468;
            uint256 era = z / 146097;
            uint256 doe = z - era * 146097;
            uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
            y = yoe + era * 400;
            uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            uint256 mp = (5 * doy + 2) / 153;
            d = doy - (153 * mp + 2) / 5 + 1;
            m = mp < 10 ? mp + 3 : mp - 9;
            if (m <= 2) y += 1;
        }
    }

    /// @notice Converts a civil date to days since 1970-01-01. Valid for years >= 1970.
    function daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        unchecked {
            if (m <= 2) y -= 1;
            uint256 era = y / 400;
            uint256 yoe = y - era * 400;
            uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
            uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
            return era * 146097 + doe - 719468;
        }
    }

    /// @notice 0 = Sunday ... 6 = Saturday.
    function weekday(uint256 dayNumber) internal pure returns (uint256) {
        return (dayNumber + 4) % 7;
    }

    /// @notice Day number of the n-th (1-based) given weekday in a month.
    function nthWeekdayOfMonth(uint256 y, uint256 m, uint256 wd, uint256 n) internal pure returns (uint256) {
        uint256 first = daysFromCivil(y, m, 1);
        uint256 offset = (7 + wd - weekday(first)) % 7;
        return first + offset + 7 * (n - 1);
    }

    /// @notice True if `ts` (UTC) falls inside US daylight saving time (2nd Sunday of March 02:00 EST to
    ///         1st Sunday of November 02:00 EDT).
    function isUsEasternDst(uint256 ts) internal pure returns (bool) {
        (uint256 y,,) = civilFromDays(ts / DAY);
        uint256 start = nthWeekdayOfMonth(y, 3, 0, 2) * DAY + 7 * HOUR; // 02:00 EST == 07:00 UTC
        uint256 end = nthWeekdayOfMonth(y, 11, 0, 1) * DAY + 6 * HOUR; // 02:00 EDT == 06:00 UTC
        return ts >= start && ts < end;
    }

    /// @notice UTC offset of US Eastern time at `ts`, in seconds (positive number: ET = UTC - offset).
    function easternOffset(uint256 ts) internal pure returns (uint256) {
        return isUsEasternDst(ts) ? 4 * HOUR : 5 * HOUR;
    }
}
// slither-disable-end divide-before-multiply
