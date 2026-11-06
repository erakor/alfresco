// DateReading.swift
//
// Reading dates typed in the launcher, for the built-ins (`days until 25/12`,
// `= today + 30 days`, `week 25 dec`, in Sources/BuiltIns/DateMath.swift) and
// the calendar (`/cal demain`, `/cal 12/11`). Dates are read day first
// (`25/12`), as ISO (`2026-12-25`), with a month name in English or French
// (`25 dec`, `1er janvier`), or as a word (`today`, `demain`, `friday`).
// Everything is worked out in the context's time zone, a day at a time, so
// daylight saving time never shifts a count.

import Foundation

/// What the built-ins' answers and date reading depend on besides the
/// input, so the self-test can pin it.
struct BuiltInContext: Sendable {
    var now: Date
    var timeZone: TimeZone
    var locale: Locale
    var makeUUID: @Sendable () -> UUID

    static var current: BuiltInContext {
        BuiltInContext(now: Date(), timeZone: .current, locale: .current, makeUUID: { UUID() })
    }
}

enum DateMath {
    /// What a date without a year means.
    enum YearlessDate {
        /// The next one, today included (`days until 25/12`).
        case next
        /// The last one, today included (`days since 1/1`).
        case previous
        /// This year's (`= 25/12 + 1 week`, `days 1/11`).
        case thisYear
    }

    /// Gregorian dates with ISO 8601 weeks (Monday first, week 1 holds the
    /// year's first Thursday), in the context's time zone.
    static func isoCalendar(_ context: BuiltInContext) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = context.timeZone
        calendar.locale = context.locale
        return calendar
    }

    // MARK: Reading dates

    private static let dayWords: [String: Int] = [
        "today": 0, "aujourd'hui": 0, "aujourd’hui": 0, "auj": 0,
        "tomorrow": 1, "demain": 1, "apres-demain": 2, "apresdemain": 2,
        "yesterday": -1, "hier": -1, "avant-hier": -2, "avanthier": -2,
    ]

    /// Calendar weekdays (1 is Sunday).
    private static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1, "dimanche": 1, "dim": 1,
        "monday": 2, "mon": 2, "lundi": 2, "lun": 2,
        "tuesday": 3, "tue": 3, "tues": 3, "mardi": 3,
        "wednesday": 4, "wed": 4, "mercredi": 4, "mer": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5, "jeudi": 5, "jeu": 5,
        "friday": 6, "fri": 6, "vendredi": 6, "ven": 6,
        "saturday": 7, "sat": 7, "samedi": 7, "sam": 7,
    ]

    /// Folded (no accents), so `décembre` is `decembre`.
    private static let months: [String: Int] = [
        "january": 1, "jan": 1, "janvier": 1, "janv": 1,
        "february": 2, "feb": 2, "fevrier": 2, "fev": 2, "fevr": 2,
        "march": 3, "mar": 3, "mars": 3,
        "april": 4, "apr": 4, "avril": 4, "avr": 4,
        "may": 5, "mai": 5,
        "june": 6, "jun": 6, "juin": 6,
        "july": 7, "jul": 7, "juillet": 7, "juil": 7,
        "august": 8, "aug": 8, "aout": 8,
        "september": 9, "sep": 9, "sept": 9, "septembre": 9,
        "october": 10, "oct": 10, "octobre": 10,
        "november": 11, "nov": 11, "novembre": 11,
        "december": 12, "dec": 12, "decembre": 12,
    ]

    /// Folded and lowercased, with a period after an abbreviation (`dec.`)
    /// and the comma in `december 25, 2027` dropped.
    static func normalize(_ text: String) -> String {
        AppIndex.fold(text).lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether `text` is a date written with words (`today`, `friday`,
    /// `25 dec`), not just digits, which could also be a division.
    static func hasWords(_ text: String) -> Bool {
        text.contains { $0.isLetter }
    }

    /// The start of the day `text` names, or nil when it names none.
    static func parseDate(_ text: String, yearless: YearlessDate, context: BuiltInContext) -> Date? {
        let text = normalize(text)
        guard !text.isEmpty else { return nil }
        let calendar = isoCalendar(context)
        let today = calendar.startOfDay(for: context.now)

        if let offset = dayWords[text] {
            return calendar.date(byAdding: .day, value: offset, to: today)
        }
        if let weekday = weekdays[text] {
            // The coming one, or the last one: a week away on that day.
            let current = calendar.component(.weekday, from: today)
            var days = (weekday - current + 7) % 7
            if yearless == .previous {
                days = days == 0 ? -7 : days - 7
            } else if days == 0 {
                days = 7
            }
            return calendar.date(byAdding: .day, value: days, to: today)
        }
        guard let parts = dayMonthYear(text) else { return nil }
        let (day, month) = (parts.day, parts.month)
        if let year = parts.year {
            return makeDate(year: year, month: month, day: day, calendar: calendar)
        }
        let thisYear = calendar.component(.year, from: today)
        switch yearless {
        case .thisYear:
            return makeDate(year: thisYear, month: month, day: day, calendar: calendar)
        case .next:
            // 29/2 can be up to 8 years away.
            for candidate in thisYear...(thisYear + 8) {
                if let date = makeDate(year: candidate, month: month, day: day, calendar: calendar), date >= today {
                    return date
                }
            }
            return nil
        case .previous:
            for candidate in stride(from: thisYear, through: thisYear - 8, by: -1) {
                if let date = makeDate(year: candidate, month: month, day: day, calendar: calendar), date <= today {
                    return date
                }
            }
            return nil
        }
    }

    /// Words `namedDay` takes: the day words and whole weekday names, not
    /// abbreviations (`auj`, `sam`, `jeu`, `mon`), which are words worth
    /// searching the calendar for.
    private static let calendarDayWords = Set(dayWords.keys).subtracting(["auj"]).union([
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi",
    ])

    /// The start of the day `text` names for the calendar (`/cal demain`,
    /// `/cal lundi`, `/cal 12/11`): the next one for a weekday or a date
    /// without a year, as `days until` reads them. Stricter than parseDate:
    /// a word alone must be a day word or a whole weekday name, and a date
    /// written with dots needs its year. nil for anything else, which the
    /// calendar searches for.
    static func namedDay(_ text: String, context: BuiltInContext) -> Date? {
        let text = normalize(text)
        if !text.contains(where: \.isNumber), !calendarDayWords.contains(text) { return nil }
        // `1.2` or `2.10` is more often a version than a day: dotted dates
        // need their year (`25.12.2026`).
        if !text.contains(where: \.isLetter), text.filter({ $0 == "." }).count == 1 { return nil }
        return parseDate(text, yearless: .next, context: context)
    }

    /// `25/12`, `25.12.2026`, `25/12/26`, `2026-12-25`, `25 dec`,
    /// `1er janvier 2027`, `dec 25`, `december 25th 2027`. Not checked
    /// against the calendar yet.
    private static func dayMonthYear(_ text: String) -> (day: Int, month: Int, year: Int?)? {
        // ISO: 2026-12-25.
        let dashed = text.split(separator: "-", omittingEmptySubsequences: false)
        if dashed.count == 3, dashed[0].count == 4,
           let year = number(dashed[0]), let month = number(dashed[1], digits: 1...2),
           let day = number(dashed[2], digits: 1...2) {
            return (day, month, year)
        }
        // Day first: 25/12, 25/12/2026, 25.12.26.
        for separator in ["/", "."] where text.contains(separator) {
            let parts = text.split(separator: Character(separator), omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3,
                  let day = number(parts[0], digits: 1...2), let month = number(parts[1], digits: 1...2)
            else { return nil }
            if parts.count == 2 { return (day, month, nil) }
            guard let year = fullYear(parts[2]) else { return nil }
            return (day, month, year)
        }
        // With a month name: 25 dec, 1er janvier 2027, dec 25, december 25th 2027.
        let words = text.split(separator: " ")
        guard words.count == 2 || words.count == 3 else { return nil }
        var year: Int?
        if words.count == 3 {
            guard words[2].count == 4, let full = number(words[2]) else { return nil }
            year = full
        }
        if let day = ordinal(words[0]), let month = months[String(words[1]).trimmingDot] {
            return (day, month, year)
        }
        if let month = months[String(words[0]).trimmingDot], let day = ordinal(words[1]) {
            return (day, month, year)
        }
        return nil
    }

    /// Digits only, `digits` of them.
    static func number(_ text: Substring, digits: ClosedRange<Int> = 1...4) -> Int? {
        guard digits.contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// `2026`, or `26` for 2026.
    private static func fullYear(_ text: Substring) -> Int? {
        guard text.count == 2 || text.count == 4, let year = number(text) else { return nil }
        return text.count == 2 ? 2000 + year : year
    }

    /// `25`, `1er`, `1st`, `2nd`, `3rd`, `25th`.
    private static func ordinal(_ text: Substring) -> Int? {
        var digits = text
        for suffix in ["er", "st", "nd", "rd", "th", "e"] where digits.hasSuffix(suffix) {
            digits = digits.dropLast(suffix.count)
            break
        }
        return number(digits, digits: 1...2)
    }

    /// nil for a day the month doesn't have (31/2).
    private static func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (1...9999).contains(year),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day, calendar.component(.month, from: date) == month
        else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// Whole days from the day of `from` to the day of `to`.
    static func days(from: Date, to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }
}

private extension String {
    /// `dec.` read as `dec`.
    var trimmingDot: String { hasSuffix(".") ? String(dropLast()) : self }
}
