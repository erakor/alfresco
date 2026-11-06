// CalendarTests.swift
//
// The `/cal` argument read as a day (`demain`, `lundi`, `12/11`) or a
// search, with a pinned clock and time zone; what Enter runs for it; which
// events a day is read from (the shared window or that day alone); and the
// events a day's list keeps: any part of that day, finished ones left out
// first past the limit. EventKit itself is never touched.

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
        enterCommand()
        fetchRange()
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
            ("25.12.2026", date(2026, 12, 25)),
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
            // Dotted numbers are versions more often than days.
            ("1.2", "1.2"),
            ("2.10", "2.10"),
            ("25.12", "25.12"),
            ("demain matin", "demain matin"),
        ]
        for (argument, text) in searches {
            let got = query(argument)
            check("/cal \(argument) is a search", got == .search(text), "got \(got)")
        }
    }

    // MARK: Enter

    private static func enterCommand() {
        guard Config.commandPrefix == "/", Config.calendarKeyword == "cal" else {
            check("calendar: Config changes /cal, Enter not tested", true)
            return
        }
        func workflows(_ json: String) -> WorkflowSet? {
            try? JSONDecoder().decode(WorkflowSet.self, from: Data(json.utf8))
        }
        let bare = #"{"keywords": ["cal"], "title": "Calendar", "url": "https://example.com/cal"}"#
        let search = #"{"keywords": ["cal"], "title": "Search", "url": "https://example.com/cal?q={query}"}"#
        guard let both = workflows(#"{"workflows": [\#(bare), \#(search)]}"#),
              let searchOnly = workflows(#"{"workflows": [\#(search)]}"#),
              let none = workflows(#"{"workflows": []}"#)
        else {
            check("calendar: the test workflows decode", false)
            return
        }
        func enter(_ input: String, _ set: WorkflowSet) -> Command? {
            let command = CommandParser.parse(input, using: set)
            let query = CalendarQuery.make(input: input, command: command, context: context)
            return CalendarQuery.enterCommand(command, query: query, using: set)
        }
        let day = enter("/cal demain", both)
        check(
            "Enter on /cal demain opens the bare /cal workflow, counted as /cal …",
            day?.url.absoluteString == "https://example.com/cal"
                && day?.source == CommandSource.workflow(keyword: "cal", withArgument: true),
            "got \(day.map { "\($0.url) \($0.source)" } ?? "nil")"
        )
        let found = enter("/cal standup", both)?.url.absoluteString
        check("Enter on /cal standup searches", found == "https://example.com/cal?q=standup", "got \(found ?? "nil")")
        let plain = enter("/cal", both)?.url.absoluteString
        check("Enter on /cal opens the calendar", plain == "https://example.com/cal", "got \(plain ?? "nil")")
        let noBare = enter("/cal demain", searchOnly)?.url.absoluteString
        check(
            "without a bare /cal workflow, Enter on /cal demain searches",
            noBare == "https://example.com/cal?q=demain", "got \(noBare ?? "nil")"
        )
        let input = "/cal demain"
        check(
            "without cal workflows, /cal demain shows no list",
            CalendarQuery.make(input: input, command: CommandParser.parse(input, using: none), context: context) == nil
        )
    }

    // MARK: Which events a day is read from

    private static func fetchRange() {
        guard Config.calendarDays == 3, Config.calendarSearchDays == 30 else {
            check("calendar: Config changes the windows, fetch ranges not tested", true)
            return
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func range(_ offset: Int) -> String {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            return CalendarProvider.fetchRangeForSelfTest(.day(day), today: today)
        }
        let cases: [(Int, String)] = [
            (-1, "day"), (0, "window 3"), (2, "window 3"), (3, "window 30"), (29, "window 30"), (30, "day"),
        ]
        for (offset, expected) in cases {
            let got = range(offset)
            check("a day \(offset) days away is read from \(expected)", got == expected, "got \(got)")
        }
        check("/cal reads 3 days", CalendarProvider.fetchRangeForSelfTest(.upcoming, today: today) == "window 3")
        check("/cal <text> reads 30 days", CalendarProvider.fetchRangeForSelfTest(.search("x"), today: today) == "window 30")
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
