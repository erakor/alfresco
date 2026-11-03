// WorldClock.swift
//
// `time tokyo` (the time there now) and `time 15:00 tokyo in paris` (a time
// somewhere, somewhere else). Places are time zone cities from the system's
// list (`new york`, `sao paulo`), a few more cities and French names,
// common abbreviations (`pst`, `cet`), `utc+2`, and `here`.

import Foundation

enum WorldClock {
    struct Place: Equatable, Sendable {
        let name: String
        let timeZone: TimeZone
    }

    /// The answer to `time <argument>`, or nil when it names no place, so
    /// the input goes to apps and the fallback search instead (`time
    /// management` is a search, not a time zone).
    static func answer(for argument: String, context: BuiltInContext) -> BuiltInAnswer? {
        // A leading space, so "in tokyo" splits like "15:00 in tokyo".
        let text = " " + AppIndex.fold(argument.trimmingCharacters(in: .whitespaces))
        var sourceText = text
        var target: Place?
        if let parts = BuiltIns.splitOnLastSeparator(text) {
            guard let named = place(named: String(parts.right), context: context) else { return nil }
            target = named
            sourceText = String(parts.left)
        }
        let (clock, rest) = parseClock(sourceText.trimmingCharacters(in: .whitespaces))
        var source: Place?
        if !rest.isEmpty {
            guard let named = place(named: rest, context: context) else { return nil }
            source = named
        }

        guard let clock else {
            // No time given: now, in the one place named, or in both.
            guard let from = source ?? target else { return nil }
            if let source, let target { return conversion(at: context.now, from: source, to: target, context: context) }
            return now(in: from, context: context)
        }
        // A time with nowhere to convert it to: nothing to show.
        guard source != nil || target != nil else { return nil }
        let from = source ?? local(context)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = from.timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: context.now)
        components.hour = clock.hour
        components.minute = clock.minute
        guard let date = calendar.date(from: components) else { return nil }
        return conversion(at: date, from: from, to: target ?? local(context), context: context)
    }

    // MARK: Answers

    private static func now(in place: Place, context: BuiltInContext) -> BuiltInAnswer {
        let time = format(context.now, template: "jmm", in: place.timeZone, context: context)
        let day = format(context.now, template: "EEEdMMM", in: place.timeZone, context: context)
        return .result(
            kind: .time,
            hint: "\(place.name) \(time), \(day)  ↩ Copy",
            value: copyText(context.now, in: place.timeZone),
            detail: "\(place.name): \(day) \(time) (\(offsetName(place.timeZone, at: context.now)))"
        )
    }

    private static func conversion(at date: Date, from: Place, to: Place, context: BuiltInContext) -> BuiltInAnswer {
        let fromTime = format(date, template: "jmm", in: from.timeZone, context: context)
        let toTime = format(date, template: "jmm", in: to.timeZone, context: context)
        let shift: String
        switch dayNumber(of: date, in: to.timeZone) - dayNumber(of: date, in: from.timeZone) {
        case 0: shift = ""
        case let days where days > 0: shift = days == 1 ? " (+1 day)" : " (+\(days) days)"
        case let days: shift = days == -1 ? " (-1 day)" : " (\(days) days)"
        }
        func describe(_ place: Place, _ time: String) -> String {
            let day = format(date, template: "EEEdMMM", in: place.timeZone, context: context)
            return "\(place.name): \(day) \(time) (\(offsetName(place.timeZone, at: date)))"
        }
        return .result(
            kind: .time,
            hint: "\(fromTime) \(from.name) = \(toTime) \(to.name)\(shift)  ↩ Copy",
            value: copyText(date, in: to.timeZone),
            detail: describe(from, fromTime) + "\n" + describe(to, toTime)
        )
    }

    /// What Enter copies: always "HH:mm" (22:05), whatever the Mac's
    /// language, so it pastes cleanly. The hint follows the language (and
    /// can read "10:05 PM", with a narrow no-break space).
    private static func copyText(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func format(_ date: Date, template: String, in zone: TimeZone, context: BuiltInContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// Days since 1970 of the calendar date `date` falls on in `zone`, to
    /// tell whether a conversion lands on another day.
    private static func dayNumber(of date: Date, in zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? zone
        guard let start = calendar.date(from: components) else { return 0 }
        return Int((start.timeIntervalSince1970 / 86400).rounded(.down))
    }

    /// "UTC+9", "UTC-3:30", "UTC".
    static func offsetName(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "UTC" }
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        let hours = minutes / 60
        return minutes % 60 == 0
            ? "UTC\(sign)\(hours)"
            : "UTC\(sign)\(hours):" + String(format: "%02d", minutes % 60)
    }

    // MARK: Clock

    /// A time at the start of `text` ("15:00", "15h", "15h30", "9am",
    /// "9:30 pm"; a bare number is not one) and what follows it, trimmed.
    /// Without one, nil and the whole text.
    static func parseClock(_ text: String) -> (clock: (hour: Int, minute: Int)?, rest: String) {
        let characters = Array(text)
        var index = 0
        func number(maxDigits: Int) -> (value: Int, digits: Int) {
            var value = 0
            var digits = 0
            while index < characters.count, digits < maxDigits,
                  characters[index].isASCII, let digit = characters[index].wholeNumberValue {
                value = value * 10 + digit
                digits += 1
                index += 1
            }
            return (value, digits)
        }
        let notAClock: (clock: (hour: Int, minute: Int)?, rest: String) = (nil, text)

        let first = number(maxDigits: 2)
        guard first.digits > 0 else { return notAClock }
        var hour = first.value
        var minute = 0
        var marked = false
        if index < characters.count, characters[index] == ":" || characters[index] == "h" {
            let separator = characters[index]
            index += 1
            let minutes = number(maxDigits: 2)
            if minutes.digits == 2 {
                minute = minutes.value
            } else if !(separator == "h" && minutes.digits == 0) {
                return notAClock
            }
            marked = true
        }
        var afterSpaces = index
        while afterSpaces < characters.count, characters[afterSpaces] == " " { afterSpaces += 1 }
        if afterSpaces + 1 < characters.count,
           characters[afterSpaces] == "a" || characters[afterSpaces] == "p",
           characters[afterSpaces + 1] == "m",
           afterSpaces + 2 == characters.count || characters[afterSpaces + 2] == " " {
            guard (1...12).contains(hour) else { return notAClock }
            let pm = characters[afterSpaces] == "p"
            hour = hour % 12 + (pm ? 12 : 0)
            index = afterSpaces + 2
            marked = true
        }
        guard marked, hour < 24, minute < 60,
              index == characters.count || characters[index] == " "
        else { return notAClock }
        let rest = String(characters[index...]).trimmingCharacters(in: .whitespaces)
        return (clock: (hour: hour, minute: minute), rest: rest)
    }

    // MARK: Places

    /// `name` as a place: here, UTC or an offset from it, a city of ours, a
    /// city of the system's time zones, or a common abbreviation.
    static func place(named name: String, context: BuiltInContext) -> Place? {
        // Before normalize, which turns the "-" of "utc-5" into a space.
        if let offset = offsetPlace(AppIndex.fold(name).trimmingCharacters(in: .whitespaces)) { return offset }
        let name = normalize(name)
        guard !name.isEmpty else { return nil }
        if ["here", "local", "ici"].contains(name) { return local(context) }
        if ["utc", "gmt", "z"].contains(name), let utc = TimeZone(secondsFromGMT: 0) {
            return Place(name: "UTC", timeZone: utc)
        }
        if let city = cities[name], let zone = TimeZone(identifier: city.identifier) {
            return Place(name: city.name, timeZone: zone)
        }
        if let identifier = systemCities[name], let zone = TimeZone(identifier: identifier) {
            return Place(name: cityName(of: identifier), timeZone: zone)
        }
        let abbreviation = name.uppercased()
        if let identifier = abbreviations[abbreviation], let zone = TimeZone(identifier: identifier) {
            return Place(name: abbreviation, timeZone: zone)
        }
        return nil
    }

    /// The abbreviations `time` knows, each standing for its region (so
    /// `pst` follows daylight saving time). A short list rather than
    /// TimeZone.abbreviationDictionary, whose CAT, ART, EAT or WET would
    /// turn `time cat` into a clock instead of a search.
    private static let abbreviations: [String: String] = [
        "CET": "Europe/Paris", "CEST": "Europe/Paris",
        "EET": "Europe/Athens", "EEST": "Europe/Athens",
        "BST": "Europe/London", "MSK": "Europe/Moscow",
        "EST": "America/New_York", "EDT": "America/New_York",
        "CST": "America/Chicago", "CDT": "America/Chicago",
        "MST": "America/Denver", "MDT": "America/Denver",
        "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles",
        "AKST": "America/Anchorage", "AKDT": "America/Anchorage",
        "HST": "Pacific/Honolulu",
        "BRT": "America/Sao_Paulo",
        "IST": "Asia/Kolkata", "HKT": "Asia/Hong_Kong", "SGT": "Asia/Singapore",
        "JST": "Asia/Tokyo", "KST": "Asia/Seoul",
        "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney",
        "ACST": "Australia/Adelaide", "AWST": "Australia/Perth",
        "NZST": "Pacific/Auckland", "NZDT": "Pacific/Auckland",
    ]

    private static func local(_ context: BuiltInContext) -> Place {
        Place(name: cityName(of: context.timeZone.identifier), timeZone: context.timeZone)
    }

    /// "utc+2", "gmt-5", "utc+5:30", "utc+0530".
    private static func offsetPlace(_ name: String) -> Place? {
        guard name.hasPrefix("utc") || name.hasPrefix("gmt") else { return nil }
        let rest = name.dropFirst(3).filter { $0 != " " }
        guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
        let digits = rest.dropFirst().filter { $0 != ":" }
        guard (1...4).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let hours: Int
        let minutes: Int
        if digits.count <= 2 {
            hours = Int(digits) ?? 99
            minutes = 0
        } else {
            hours = Int(digits.dropLast(2)) ?? 99
            minutes = Int(digits.suffix(2)) ?? 99
        }
        guard hours <= 14, minutes < 60,
              let zone = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
        else { return nil }
        return Place(name: offsetName(zone, at: Date()), timeZone: zone)
    }

    /// Folded, with "-" and "_" as spaces and runs of spaces as one.
    private static func normalize(_ text: String) -> String {
        let spaced = String(AppIndex.fold(text).map { $0 == "-" || $0 == "_" ? " " : $0 })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// "America/New_York" → "New York".
    private static func cityName(of identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier)
            .replacingOccurrences(of: "_", with: " ")
    }

    /// Each system time zone by its whole identifier ("america/new york"),
    /// and by its city alone ("new york", "sao paulo") outside the island and
    /// polar regions, whose names are often plain words (Christmas, Easter,
    /// Wake, Troll): `time christmas` stays a search, and
    /// `time indian/christmas` or the cities table reaches them. The Etc/
    /// zones are left out: their signs are reversed (Etc/GMT+5 is UTC-5);
    /// `utc+5` covers them.
    private static let systemCities: [String: String] = {
        let wordRegions = ["Antarctica/", "Arctic/", "Atlantic/", "Indian/", "Pacific/"]
        let wordCities: Set<String> = ["center", "resolute", "cayenne"]
        var index: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers where !identifier.hasPrefix("Etc/") {
            var keys = [normalize(identifier)]
            let city = normalize(cityName(of: identifier))
            if !wordRegions.contains(where: { identifier.hasPrefix($0) }), !wordCities.contains(city) { keys.append(city) }
            for key in keys where index[key] == nil { index[key] = identifier }
        }
        return index
    }()

    /// Cities that have no time zone of their own, and French names.
    private static let cities: [String: (identifier: String, name: String)] = {
        let table: [(String, String, [String])] = [
            ("America/New_York", "New York", ["nyc", "ny", "boston", "washington", "dc", "miami", "atlanta", "philadelphia"]),
            ("America/Chicago", "Chicago", ["dallas", "houston", "austin"]),
            ("America/Los_Angeles", "Los Angeles", ["la", "sf", "san francisco", "seattle", "portland", "las vegas", "san diego"]),
            ("America/Toronto", "Toronto", ["montreal", "ottawa", "quebec"]),
            ("America/Sao_Paulo", "São Paulo", ["rio", "rio de janeiro"]),
            ("Europe/London", "London", ["londres", "manchester", "edinburgh", "edimbourg"]),
            ("Europe/Paris", "Paris", ["lyon", "marseille", "toulouse", "bordeaux", "nantes", "lille", "nice", "strasbourg", "rennes", "montpellier"]),
            ("Europe/Berlin", "Berlin", ["munich", "munchen", "hamburg", "hambourg", "frankfurt", "francfort", "cologne"]),
            ("Europe/Madrid", "Madrid", ["barcelona", "barcelone", "seville", "valencia", "valence"]),
            ("Europe/Rome", "Rome", ["milan", "milano", "naples", "florence", "venise", "venice"]),
            ("Europe/Zurich", "Zurich", ["geneva", "geneve", "bern", "berne"]),
            ("Europe/Brussels", "Brussels", ["bruxelles"]),
            ("Europe/Lisbon", "Lisbon", ["lisbonne", "porto"]),
            ("Europe/Warsaw", "Warsaw", ["varsovie"]),
            ("Europe/Vienna", "Vienna", ["vienne"]),
            ("Europe/Copenhagen", "Copenhagen", ["copenhague"]),
            ("Europe/Athens", "Athens", ["athenes"]),
            ("Europe/Moscow", "Moscow", ["moscou"]),
            ("Africa/Cairo", "Cairo", ["le caire"]),
            ("Asia/Jerusalem", "Jerusalem", ["tel aviv", "jerusalem"]),
            ("Asia/Dubai", "Dubai", ["abu dhabi", "dubai"]),
            ("Asia/Kolkata", "India", ["india", "inde", "mumbai", "bombay", "delhi", "new delhi", "bangalore", "bengaluru", "chennai"]),
            ("Asia/Shanghai", "China", ["china", "chine", "beijing", "pekin", "shenzhen", "guangzhou"]),
            ("Asia/Tokyo", "Tokyo", ["japan", "japon", "osaka", "kyoto"]),
            ("Asia/Seoul", "Seoul", ["seoul", "korea", "coree"]),
            ("Asia/Singapore", "Singapore", ["singapour"]),
            ("Australia/Sydney", "Sydney", ["canberra"]),
            // Island zones, which systemCities only knows by their identifier.
            ("Pacific/Honolulu", "Honolulu", ["honolulu", "hawaii"]),
            ("Pacific/Auckland", "Auckland", ["auckland", "wellington", "new zealand", "nouvelle zelande"]),
            ("Pacific/Tahiti", "Tahiti", ["tahiti", "papeete"]),
            ("Pacific/Noumea", "Nouméa", ["noumea", "nouvelle caledonie"]),
            ("Pacific/Fiji", "Fiji", ["fiji", "fidji"]),
            ("Pacific/Guam", "Guam", ["guam"]),
            ("Atlantic/Reykjavik", "Reykjavik", ["reykjavik", "iceland", "islande"]),
            ("Atlantic/Azores", "Azores", ["azores", "acores"]),
            ("Atlantic/Madeira", "Madeira", ["madeira", "madere"]),
            ("Atlantic/Canary", "Canary Islands", ["canary", "canaries", "tenerife"]),
            ("Atlantic/Bermuda", "Bermuda", ["bermuda", "bermudes"]),
            ("Atlantic/Cape_Verde", "Cape Verde", ["cape verde", "cap vert"]),
            ("Indian/Reunion", "Réunion", ["reunion", "la reunion"]),
            ("Indian/Mauritius", "Mauritius", ["mauritius", "maurice"]),
            ("Indian/Maldives", "Maldives", ["maldives"]),
            ("Indian/Mayotte", "Mayotte", ["mayotte"]),
        ]
        var cities: [String: (identifier: String, name: String)] = [:]
        for (identifier, name, aliases) in table {
            for alias in aliases where cities[alias] == nil { cities[alias] = (identifier, name) }
        }
        return cities
    }()
}
