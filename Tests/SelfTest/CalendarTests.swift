// CalendarTests.swift
//
// The `/cal` argument read as a day (`demain`, `lundi`, `12/11`) or a
// search, with a pinned clock and time zone, and the events a day's list
// keeps: any part of that day, finished ones left out first past the limit.
// EventKit itself is never touched.

import Foundation

@MainActor
enum CalendarTests {
    /// Tuesday 3 November 2026, 14:05:09 in Paris (UTC+1), as in
    /// BuiltInTests.
    private static let context = BuiltInContext(
        now: Date(timeIntervalSince1970: 1_793_711_109),
        timeZone: TimeZone(identifier: "Europe/Paris")!,
        locale: Locale(identifier: "fr_FR"),
        makeUUID: { UUID() }
    )

    private static let paris = DateMath.isoCalendar(context)

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        paris.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func run() {
        queries()
        dayList()
    }

    // MARK: /cal <argument>

    private static func queries() {
        func query(_ argument: String?) -> CalendarQuery {
            CalendarQuery.make(argument: argument, context: context)
        }
        let days: [(String, Date)] = [
            ("demain", date(2026, 11, 4)),
            ("Demain", date(2026, 11, 4)),
            ("tomorrow", date(2026, 11, 4)),
            ("aujourd'hui", date(2026, 11, 3)),
            ("après-demain", date(2026, 11, 5)),
            ("hier", date(2026, 11, 2)),
            ("lundi", date(2026, 11, 9)),
            ("friday", date(2026, 11, 6)),
            // Today's weekday is next week's, as in `days until tuesday`.
            ("mardi", date(2026, 11, 10)),
            ("12/11", date(2026, 11, 12)),
            ("3/11", date(2026, 11, 3)),
            // A date without a year that has passed is next year's.
            ("1/11", date(2027, 11, 1)),
            ("25 déc", date(2026, 12, 25)),
            ("1er janvier", date(2027, 1, 1)),
            ("2027-02-14", date(2027, 2, 14)),
        ]
        for (argument, day) in days {
            let got = query(argument)
            check("/cal \(argument) is that day", got == .day(day), "got \(got)")
        }
        check("/cal alone is upcoming", query(nil) == .upcoming)
        let searches: [(String, String)] = [
            ("standup", "standup"),
            ("Réunion", "reunion"),
            // Weekday abbreviations are words worth searching for.
            ("sam", "sam"),
            ("jeu", "jeu"),
            ("mon", "mon"),
            ("sprint 12", "sprint 12"),
            ("31/2", "31/2"),
            ("demain matin", "demain matin"),
        ]
        for (argument, text) in searches {
            let got = query(argument)
            check("/cal \(argument) is a search", got == .search(text), "got \(got)")
        }
    }

    // MARK: A day's events

    private static func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(
            title: title, start: start, end: end, isAllDay: allDay, calendarColor: nil,
            calendarName: "", location: nil, searchText: AppIndex.fold(title)
        )
    }

    private static func dayList() {
        let events = [
            event("yesterday all day", date(2026, 11, 2), date(2026, 11, 3), allDay: true),
            event("night", date(2026, 11, 2, 22), date(2026, 11, 3, 1)),
            event("today all day", date(2026, 11, 3), date(2026, 11, 4), allDay: true),
            event("morning", date(2026, 11, 3, 9), date(2026, 11, 3, 10)),
            event("now", date(2026, 11, 3, 14), date(2026, 11, 3, 15)),
            event("tomorrow", date(2026, 11, 4), date(2026, 11, 4, 1)),
        ]
        func list(limit: Int) -> (titles: [String], hidden: Int) {
            let found = CalendarProvider.dayList(
                events, on: date(2026, 11, 3), now: context.now, limit: limit, calendar: paris
            )
            return (found.shown.map(\.title), found.hidden)
        }
        let all = list(limit: 8)
        check(
            "a day lists every event touching it, finished ones included",
            all.titles == ["night", "today all day", "morning", "now"] && all.hidden == 0,
            "got \(all)"
        )
        let two = list(limit: 2)
        check(
            "past the limit, finished events are left out first",
            two.titles == ["today all day", "now"] && two.hidden == 2,
            "got \(two)"
        )
        let one = list(limit: 1)
        check(
            "then the latest events are counted as hidden",
            one.titles == ["today all day"] && one.hidden == 3,
            "got \(one)"
        )
        let instant = CalendarProvider.dayList(
            [event("reminder", date(2026, 11, 4), date(2026, 11, 4))],
            on: date(2026, 11, 4), now: context.now, limit: 8, calendar: paris
        )
        check("an event of no length at midnight is on that day", instant.shown.count == 1)
    }
}
