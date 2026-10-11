//
//  RecentDateStyleTests.swift
//  scoreTests
//
//  RecentDateStyle: how the home screen's recent matches show their date.
//

import Foundation
import Testing

@testable import score

@Suite("RecentDateStyle")
struct RecentDateStyleTests {
    // nonisolated: the @Test arguments below are evaluated off the main actor
    nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
        return calendar
    }()

    /// 11 October 2026, 09:41 in London.
    nonisolated static let now = date(10, 11, 9, minute: 41)

    nonisolated static func date(_ month: Int, _ day: Int, _ hour: Int, minute: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
            ?? .distantPast
    }

    @Test(
        "Today's time, yesterday, a weekday within the week, then the date",
        arguments: [
            (RecentDateStyleTests.date(10, 11, 0), RecentDateStyle.time),  // earlier today
            (RecentDateStyleTests.date(10, 10, 23), .yesterday),  // under 24 hours ago, but yesterday
            (RecentDateStyleTests.date(10, 10, 0), .yesterday),
            (RecentDateStyleTests.date(10, 9, 18), .weekday),
            (RecentDateStyleTests.date(10, 5, 18), .weekday),  // six days ago
            (RecentDateStyleTests.date(10, 4, 18), .dayMonth),  // a week ago
            (RecentDateStyleTests.date(1, 2, 18), .dayMonth),
            (RecentDateStyleTests.date(12, 30, 18, year: 2025), .dayMonthYear),
            (RecentDateStyleTests.date(10, 12, 18), .dayMonth),  // tomorrow (clock skew): no relative wording
        ])
    func style(date: Date, expected: RecentDateStyle) {
        #expect(RecentDateStyle(date: date, now: Self.now, calendar: Self.calendar) == expected)
    }

    @Test("Day counting survives a year boundary")
    func acrossNewYear() {
        let now = Self.date(1, 2, 9, year: 2027)
        #expect(RecentDateStyle(date: Self.date(1, 1, 18, year: 2027), now: now, calendar: Self.calendar) == .yesterday)
        #expect(RecentDateStyle(date: Self.date(12, 30, 18), now: now, calendar: Self.calendar) == .weekday)
        #expect(RecentDateStyle(date: Self.date(12, 20, 18), now: now, calendar: Self.calendar) == .dayMonthYear)
    }

    @Test("Day counting survives the clocks going back (a 25-hour day in London)")
    func acrossDaylightSavingEnd() {
        let now = Self.date(10, 26, 9)  // clocks went back on 25 October 2026
        #expect(RecentDateStyle(date: Self.date(10, 25, 18), now: now, calendar: Self.calendar) == .yesterday)
        #expect(
            RecentDateStyle(date: Self.date(10, 25, 0, minute: 30), now: now, calendar: Self.calendar) == .yesterday)
        #expect(RecentDateStyle(date: Self.date(10, 24, 23), now: now, calendar: Self.calendar) == .weekday)
    }
}
