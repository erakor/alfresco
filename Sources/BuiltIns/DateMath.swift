// DateMath.swift
//
// Dates in the launcher: days between dates (`days until 25/12`,
// `days since 1/1`, `days from 1/1 to 25/12`), date arithmetic after the
// calculator prefix (`= today + 30 days`, `= 25/12 - today`) and ISO week
// numbers (`week`, `week 25/12`, `week 12`). Dates are read by the shared
// part of DateMath (Sources/Shared/DateReading.swift), which the calendar
// uses too.

import Foundation

extension DateMath {
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
