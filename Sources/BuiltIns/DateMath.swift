// DateMath.swift
//
// Dates in the launcher: days between dates (`days until 25/12`,
// `days since 1/1`, `days from 1/1 to 25/12`), date arithmetic after the
// calculator prefix (`= today + 30 days`, `= 25/12 - today`) and ISO week
// numbers (`week`, `week 25/12`, `week 12`). Dates are read day first
// (`25/12`), as ISO (`2026-12-25`), with a month name in English or French
// (`25 dec`, `1er janvier`), or as a word (`today`, `demain`, `friday`).
// Everything is worked out in the context's time zone, a day at a time, so
// daylight saving time never shifts a count.

import Foundation

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
    private static func number(_ text: Substring, digits: ClosedRange<Int> = 1...4) -> Int? {
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

    // MARK: Showing dates

    /// `Fri 25 Dec 2026` in the Mac's language.
    static func display(_ date: Date, context: BuiltInContext) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMMyyyy")
        return formatter.string(from: date)
    }

    /// `2026-12-25`, what Enter copies for a date.
    static func iso(_ date: Date, context: BuiltInContext) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = context.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func dayCount(_ days: Int) -> String {
        abs(days) == 1 ? "\(days) day" : "\(days) days"
    }

    /// "7 weeks and 3 days" for a hint's tooltip; nil under a week.
    private static func inWeeks(_ days: Int) -> String? {
        let days = abs(days)
        guard days >= 7 else { return nil }
        let weeks = days / 7, rest = days % 7
        let weekText = weeks == 1 ? "1 week" : "\(weeks) weeks"
        return rest == 0 ? weekText : "\(weekText) and \(dayCount(rest))"
    }

    private static let help = "Type a date: 25/12, 2026-12-25, 25 dec, friday, demain"

    // MARK: days

    /// `days until <date>` (`till`, `to`, `jusqu'au`), `days since <date>`
    /// (`depuis`), `days <date>`, `days from <date> to <date>` (`between …
    /// and …`, `du … au …`). Enter copies the number of days. nil for `days`
    /// alone or followed by something that is no date, which is left to
    /// apps and the search.
    static func days(_ argument: String?, context: BuiltInContext) -> BuiltInAnswer? {
        guard let argument else { return nil }
        let text = normalize(argument)
        let calendar = isoCalendar(context)
        let today = calendar.startOfDay(for: context.now)

        // Two dates.
        for (lead, separators) in [("from ", [" to ", " until ", " -> ", " → "]), ("between ", [" and "]),
                                   ("du ", [" au "]), ("entre ", [" et "])] where text.hasPrefix(lead) {
            let rest = String(text.dropFirst(lead.count))
            guard let separator = separators.first(where: { rest.contains($0) }),
                  let range = rest.range(of: separator, options: .backwards)
            else { return .incomplete(kind: .date, message: "Type two dates: days from 1/1 to 25/12") }
            let firstText = String(rest[..<range.lowerBound]), secondText = String(rest[range.upperBound...])
            guard let first = parseDate(firstText, yearless: .thisYear, context: context) else {
                return .incomplete(kind: .date, message: unknownDate(firstText))
            }
            guard let second = parseDate(secondText, yearless: .thisYear, context: context) else {
                return .incomplete(kind: .date, message: secondText.isEmpty ? help : unknownDate(secondText))
            }
            let count = days(from: first, to: second, calendar: calendar)
            let value = String(abs(count))
            return .result(
                kind: .date,
                hint: "\(dayCount(abs(count))) from \(display(first, context: context)) "
                    + "to \(display(second, context: context))  ↩ Copy",
                value: value, detail: inWeeks(count)
            )
        }

        // One date, from today.
        let leads: [(String, YearlessDate)] = [
            ("until", .next), ("till", .next), ("to", .next), ("before", .next),
            ("jusqu'au", .next), ("jusqu’au", .next), ("jusqu'a", .next), ("jusqu’a", .next), ("avant", .next),
            ("since", .previous), ("depuis", .previous),
        ]
        var dateText = text
        var yearless = YearlessDate.thisYear
        var led = false
        for (lead, meaning) in leads {
            if text == lead {
                return .incomplete(kind: .date, message: help)
            }
            if text.hasPrefix(lead + " ") {
                dateText = String(text.dropFirst(lead.count + 1))
                yearless = meaning
                led = true
                break
            }
        }
        guard let date = parseDate(dateText, yearless: yearless, context: context) else {
            // `days gone`: a search, unless `until` said it was ours.
            return led ? .incomplete(kind: .date, message: unknownDate(dateText)) : nil
        }
        let count = days(from: today, to: date, calendar: calendar)
        let shown = display(date, context: context)
        let hint: String
        if count == 0 {
            hint = "0 days: \(shown) is today  ↩ Copy"
        } else if count > 0 {
            hint = "\(dayCount(count)) until \(shown)  ↩ Copy"
        } else {
            hint = "\(dayCount(-count)) since \(shown)  ↩ Copy"
        }
        return .result(kind: .date, hint: hint, value: String(abs(count)), detail: inWeeks(count))
    }

    private static func unknownDate(_ text: String) -> String {
        "Unknown date \"\(text)\": try 25/12, 2026-12-25, 25 dec, friday"
    }

    // MARK: = today + 30 days

    private enum Unit: Sendable {
        case day, month, year

        var component: Calendar.Component {
            switch self {
            case .day: return .day
            case .month: return .month
            case .year: return .year
            }
        }
    }

    private enum Term {
        case date(Date)
        case duration(Unit, Int)
    }

    private static let units: [String: (Unit, Int)] = [
        "d": (.day, 1), "day": (.day, 1), "days": (.day, 1), "j": (.day, 1), "jour": (.day, 1), "jours": (.day, 1),
        "w": (.day, 7), "wk": (.day, 7), "wks": (.day, 7), "week": (.day, 7), "weeks": (.day, 7),
        "sem": (.day, 7), "semaine": (.day, 7), "semaines": (.day, 7),
        "mo": (.month, 1), "month": (.month, 1), "months": (.month, 1), "mois": (.month, 1),
        "y": (.year, 1), "yr": (.year, 1), "yrs": (.year, 1), "year": (.year, 1), "years": (.year, 1),
        "an": (.year, 1), "ans": (.year, 1), "annee": (.year, 1), "annees": (.year, 1),
    ]

    /// `30 days`, `30d`, `2 semaines`, `1 month`: nil when it isn't one,
    /// `.failure` for a number with no unit (yet).
    private static func duration(_ text: String) -> Result<(Unit, Int), DateMathError>? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 6, let amount = Int(digits) else { return nil }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        if unit.isEmpty { return .failure(.missingUnit) }
        guard let found = units[unit] else { return nil }
        return .success((found.0, amount * found.1))
    }

    private enum DateMathError: Error {
        case missingUnit
    }

    /// `<date> (+|-) <amount> <unit> …` gives a date, `<date> - <date>` a
    /// number of days. nil when `text` (what follows the calculator prefix)
    /// is no date calculation, so the calculator takes it: a date written
    /// in digits alone (`25/12 - 1/1`) is a division, unless a duration or
    /// a word date (`today`) is part of it.
    static func calculate(_ text: String, context: BuiltInContext) -> BuiltInAnswer? {
        let parts = split(normalize(text))
        guard let first = parts.first,
              let start = parseDate(first.text, yearless: .thisYear, context: context)
        else { return nil }
        // A word date makes the input ours, even while it is unfinished.
        let ours = hasWords(first.text)
        let prefix = Config.calculatorPrefix ?? ""
        let calendar = isoCalendar(context)

        var terms: [(sign: Int, term: Term)] = []
        for part in parts.dropFirst() {
            if part.text.isEmpty {
                guard ours else { return nil }
                return .incomplete(kind: .date, message: "Add days, weeks, months or years: \(prefix) today + 30 days")
            }
            switch duration(part.text) {
            case .success(let (unitKind, amount))?:
                terms.append((part.sign, .duration(unitKind, amount)))
                continue
            case .failure?:
                guard ours else { return nil }
                return .incomplete(kind: .date, message: "Add a unit: days, weeks, months or years")
            case nil:
                break
            }
            if part.sign < 0, let date = parseDate(part.text, yearless: .thisYear, context: context) {
                terms.append((part.sign, .date(date)))
                continue
            }
            guard ours else { return nil }
            return .incomplete(kind: .date, message: "Unknown date or duration \"\(part.text)\"")
        }
        let hasDuration = terms.contains { if case .duration = $0.term { return true } else { return false } }
        let dates = terms.filter { if case .date = $0.term { return true } else { return false } }
        // Digits alone, such as 25/12 - 1/1, stay a division.
        guard ours || hasDuration || parts.contains(where: { hasWords($0.text) }) else { return nil }

        // `<date> - <date>`: the days between them.
        if case .date(let other)? = dates.first?.term {
            guard terms.count == 1 else {
                return .incomplete(kind: .date, message: "Subtract one date from another, without durations")
            }
            let count = days(from: other, to: start, calendar: calendar)
            return .result(kind: .date, hint: "\(dayCount(count))  ↩ Copy", value: String(count), detail: inWeeks(count))
        }

        var date = start
        for (sign, term) in terms {
            guard case .duration(let unitKind, let amount) = term,
                  let moved = calendar.date(byAdding: unitKind.component, value: sign * amount, to: date)
            else { return .incomplete(kind: .date, message: "No such date") }
            date = moved
        }
        let week = calendar.component(.weekOfYear, from: date)
        let count = days(from: context.now, to: date, calendar: calendar)
        let relative = count == 0 ? "today" : count > 0 ? "in \(dayCount(count))" : "\(dayCount(-count)) ago"
        return .result(
            kind: .date, hint: "\(display(date, context: context))  ↩ Copy", value: iso(date, context: context),
            detail: "Week \(week), \(relative)"
        )
    }

    /// `today + 30 days - 1 week` as signed parts. A `-` between two digits
    /// is part of a date (`2026-12-25`), so is the one in `avant-hier` and
    /// `apres-demain`.
    private static func split(_ text: String) -> [(sign: Int, text: String)] {
        let text = text.replacingOccurrences(of: "apres-demain", with: "apresdemain")
            .replacingOccurrences(of: "avant-hier", with: "avanthier")
        let characters = Array(text)
        var parts: [(sign: Int, text: String)] = []
        var sign = 1
        var current = ""
        for (index, character) in characters.enumerated() {
            let isMinus = character == "-" || character == "−"
            let betweenDigits = index > 0 && index + 1 < characters.count
                && characters[index - 1].isNumber && characters[index + 1].isNumber
            if character == "+" || (isMinus && !betweenDigits) {
                parts.append((sign, current.trimmingCharacters(in: .whitespaces)))
                sign = character == "+" ? 1 : -1
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append((sign, current.trimmingCharacters(in: .whitespaces)))
        return parts
    }

    // MARK: week

    /// `week` (this week), `week <date>` (the week that day is in): Enter
    /// copies the ISO week number. `week 12`, `week 12 2027`: Enter copies
    /// that week's Monday. nil for anything else after `week`.
    static func week(_ argument: String?, context: BuiltInContext) -> BuiltInAnswer? {
        let calendar = isoCalendar(context)
        let text = argument.map(normalize) ?? ""
        let words = text.split(separator: " ")

        // A week number, and maybe its year (`week 25 dec` is a date).
        if let first = words.first, let weekNumber = Self.number(first, digits: 1...2),
           words.count == 1 || (words.count == 2 && words[1].count == 4 && Self.number(words[1]) != nil) {
            let year = words.count == 2 ? Self.number(words[1]) ?? 0 : calendar.component(.yearForWeekOfYear, from: context.now)
            guard let monday = calendar.date(from: DateComponents(weekday: 2, weekOfYear: weekNumber, yearForWeekOfYear: year)),
                  calendar.component(.weekOfYear, from: monday) == weekNumber,
                  calendar.component(.yearForWeekOfYear, from: monday) == year,
                  let sunday = calendar.date(byAdding: .day, value: 6, to: monday)
            else {
                return .incomplete(kind: .week, message: "\(year) has no week \(weekNumber)")
            }
            return .result(
                kind: .week,
                hint: "Week \(weekNumber): \(display(monday, context: context)) – \(display(sunday, context: context))  ↩ Copy",
                value: iso(monday, context: context), detail: "ISO week \(weekNumber) of \(year); Enter copies its Monday"
            )
        }

        let day: Date
        if text.isEmpty {
            day = calendar.startOfDay(for: context.now)
        } else if let date = parseDate(text, yearless: .thisYear, context: context) {
            day = date
        } else {
            return nil
        }
        let weekNumber = calendar.component(.weekOfYear, from: day)
        let year = calendar.component(.yearForWeekOfYear, from: day)
        let weekday = calendar.component(.weekday, from: day)
        // Monday is weekday 2; Sunday (1) ends the week.
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day) ?? day
        let sunday = calendar.date(byAdding: .day, value: 6, to: monday) ?? day
        let ofYear = year == calendar.component(.year, from: day) ? "" : " of \(year)"
        return .result(
            kind: .week,
            hint: "Week \(weekNumber)\(ofYear): \(display(monday, context: context)) – \(display(sunday, context: context))  ↩ Copy",
            value: String(weekNumber), detail: "ISO week \(weekNumber) of \(year)"
        )
    }
}

private extension String {
    /// `dec.` read as `dec`.
    var trimmingDot: String { hasSuffix(".") ? String(dropLast()) : self }
}
