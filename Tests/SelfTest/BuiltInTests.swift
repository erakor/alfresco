// BuiltInTests.swift
//
// The launcher's built-ins: the calculator's arithmetic and errors, unit
// conversions, world clocks (with a pinned clock, zone and locale), `uuid`
// and `now`, and that a workflows.json keyword always wins over them.

import Foundation

@MainActor
enum BuiltInTests {
    /// Tuesday 3 November 2026, 14:05:09 in Paris (UTC+1), in British
    /// English (24-hour clock).
    private static let context = BuiltInContext(
        now: Date(timeIntervalSince1970: 1_793_711_109),
        timeZone: TimeZone(identifier: "Europe/Paris")!,
        locale: Locale(identifier: "en_GB"),
        makeUUID: { UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")! }
    )

    static func run() {
        guard Config.calculatorPrefix == "=", Config.timeKeyword == "time",
              Config.uuidKeyword == "uuid", Config.timestampKeyword == "now"
        else {
            check("built-ins: Config changes their keywords, nothing to test", true)
            return
        }
        calculator()
        conversions()
        worldClock()
        uuidAndNow()
        precedence()
    }

    private static func ask(_ input: String) -> BuiltInAnswer? {
        BuiltIns.answer(for: input, context: context)
    }

    private static func value(_ input: String) -> String? {
        ask(input)?.value
    }

    private static func failure(_ text: String) -> CalculatorError? {
        do {
            _ = try Calculator.evaluate(text)
            return nil
        } catch {
            return error as? CalculatorError
        }
    }

    // MARK: Calculator

    private static func calculator() {
        let cases: [(String, String)] = [
            ("= 3*14", "42"),
            ("=3*14", "42"),
            ("= 2^10", "1024"),
            ("= 2**3", "8"),
            ("= -2^2", "-4"),
            ("= 2^-1", "0.5"),
            ("= 2^3^2", "512"),
            ("= (1+2)*3", "9"),
            ("= 2(3+4)", "14"),
            ("= 1,5 + 1", "2.5"),
            ("= .5 * 4", "2"),
            ("= 0.1+0.2", "0.3"),
            ("= 1/3", "0.333333333333"),
            ("= 15% * 80", "12"),
            ("= sqrt(16)^2", "16"),
            ("= sqrt 2", "1.41421356237"),
            ("= 2pi", "6.28318530718"),
            ("= PI", "3.14159265359"),
            ("= 1e3 + 1", "1001"),
            ("= 2.5E-1", "0.25"),
            ("= 10 − 4 × 2 ÷ 4", "8"),
            ("= 2^70", "1.18059162072e+21"),
            ("= 0 * -1", "0"),
        ]
        for (input, expected) in cases {
            let answer = ask(input)
            check("built-ins: \(input) is \(expected)", answer?.value == expected, "got \(String(describing: answer))")
            check("built-ins: \(input) counts as a calculation", answer?.kind == .calculation)
        }

        check("built-ins: 1/0 is a division by zero", failure("1/0") == .divisionByZero)
        check("built-ins: 3* is incomplete", failure("3*") == .incomplete)
        check("built-ins: (1+2 is incomplete", failure("(1+2") == .incomplete)
        check("built-ins: 1+2) has an unexpected )", failure("1+2)") == .unexpected(")"))
        check("built-ins: foo is an unknown name", failure("foo") == .unknownName("foo"))
        check("built-ins: sqrt(-1) has no finite result", failure("sqrt(-1)") == .notFinite)
        check("built-ins: 10^400 has no finite result", failure("10^400") == .notFinite)
        check("built-ins: 1,000 is ambiguous, not 1", failure("1,000 * 3") == .ambiguousComma("1,000"))
        check("built-ins: 12,500 is ambiguous", failure("12,500") == .ambiguousComma("12,500"))
        check("built-ins: 0,125 is a decimal", (try? Calculator.evaluate("0,125 * 8")) == 1)
        check("built-ins: 1234,567 is a decimal", (try? Calculator.evaluate("1234,567")) == 1234.567)
        check("built-ins: 1,25 is a decimal", (try? Calculator.evaluate("1,25")) == 1.25)
        // Thousands of levels would overflow the main thread's stack.
        check("built-ins: 5000 ( are refused, not a crash",
              failure(String(repeating: "(", count: 5000) + "1") == .tooDeep)
        check("built-ins: 5000 - are refused, not a crash",
              failure(String(repeating: "-", count: 5000) + "1") == .tooDeep)
        check("built-ins: 5000 sqrt are refused, not a crash",
              failure(String(repeating: "sqrt ", count: 5000) + "1") == .tooDeep)
        check("built-ins: 50 nested ( still work",
              (try? Calculator.evaluate(String(repeating: "(", count: 50) + "1" + String(repeating: ")", count: 50))) == 1)

        // Input that is the calculator's but has no answer keeps the bar open.
        for input in ["=", "= 3*", "= 1/0", "= hello", "= 1,000 * 3"] {
            let answer = ask(input)
            check("built-ins: \(input) is incomplete (Enter beeps)",
                  answer != nil && answer?.value == nil, "got \(String(describing: answer))")
        }
    }

    // MARK: Units

    private static func conversions() {
        let cases: [(String, String)] = [
            ("= 10 km in mi", "6.21371192237"),
            ("= 10km to mi", "6.21371192237"),
            ("= 100 °C in F", "212"),
            ("= -40 f en c", "-40"),
            ("= 0 k in c", "-273.15"),
            ("= 10 in in cm", "25.4"),
            ("= 1 GiB in MiB", "1024"),
            ("= 2 Go en Mo", "2000"),
            ("= 90 min in h", "1.5"),
            ("= 2*3 kg in g", "6000"),
            ("= 36 km/h in m/s", "10"),
            ("= 1 fl oz in ml", "29.5735295625"),
            ("= 1 ha -> m2", "10000"),
            ("= 3 to in go", "3000"),
            // A unit named like a separator, as the target.
            ("= 30 cm in in", "11.811023622"),
            ("= 30 cm to in", "11.811023622"),
            ("= 30 cm -> in", "11.811023622"),
            ("= 3000 go en to", "3"),
            // "Mb" is megabits; "mb" and "MB" are megabytes.
            ("= 100 Mb in MB", "12.5"),
            ("= 1000 Mb in GB", "0.125"),
            ("= 1 MB in mb", "1"),
            ("= 8 bits in b", "1"),
            ("= 1 Gbit in Mb", "1000"),
        ]
        for (input, expected) in cases {
            let answer = ask(input)
            check("built-ins: \(input) is \(expected)", answer?.value == expected, "got \(String(describing: answer))")
            check("built-ins: \(input) counts as a conversion", answer?.kind == .conversion)
        }
        if case .result(_, let hint, _, _)? = ask("= 10 km in mi") {
            check("built-ins: a conversion's hint names the unit", hint.hasPrefix("6.21371192237 mi"), hint)
        } else {
            check("built-ins: a conversion's hint names the unit", false)
        }

        let failures: [(String, String)] = [
            ("= 10 km in kg", "Can't convert km to kg"),
            ("= 10 km in parsecs", "Unknown unit \"parsecs\""),
            ("= 10 km in", "Type the unit to convert to"),
            ("= 10 in in", "Type the unit to convert to"),
        ]
        for (input, message) in failures {
            let answer = ask(input)
            check("built-ins: \(input) says \(message)",
                  answer?.value == nil && answer?.hint == message, "got \(String(describing: answer))")
        }
        let bare = ask("= 10 km")
        check("built-ins: = 10 km asks for a unit to convert to",
              bare?.value == nil && bare?.kind == .conversion, "got \(String(describing: bare))")
        // A unit name right after a letter is not a unit: "2 pim" is not 2π m.
        check("built-ins: = 2 pim in cm is no conversion", value("= 2 pim in cm") == nil)
    }

    // MARK: Time zones

    private static func worldClock() {
        let cases: [(String, String)] = [
            ("time tokyo", "22:05"),
            ("time Tokyo", "22:05"),
            ("time in tokyo", "22:05"),
            ("time new york", "08:05"),
            ("time sao-paulo", "10:05"),
            ("time pékin", "21:05"),
            ("time utc", "13:05"),
            ("time utc+5:30", "18:35"),
            ("time utc-5", "08:05"),
            ("time utc-3:30", "09:35"),
            ("time gmt -5", "08:05"),
            ("time 15:00 utc-5 in paris", "21:00"),
            ("time pst", "05:05"),
            ("time CET", "14:05"),
            ("time honolulu", "03:05"),
            ("time reunion", "17:05"),
            ("time 15:00 tokyo", "07:00"),
            ("time 15h tokyo", "07:00"),
            ("time 15:00 in tokyo", "23:00"),
            ("time 15h30 to tokyo", "23:30"),
            ("time 9am new york in paris", "15:00"),
            ("time 9:30 pm london en paris", "22:30"),
            ("time 12am utc in paris", "01:00"),
            ("time tokyo in london", "13:05"),
        ]
        for (input, expected) in cases {
            let answer = ask(input)
            check("built-ins: \(input) is \(expected)", answer?.value == expected, "got \(String(describing: answer))")
            check("built-ins: \(input) counts as a time", answer?.kind == .time)
        }

        let nextDay = ask("time 11pm sf in paris")
        check("built-ins: 11pm in San Francisco is 08:00 the next day in Paris",
              nextDay?.value == "08:00" && nextDay?.hint.contains("(+1 day)") == true,
              "got \(String(describing: nextDay))")
        let sameDay = ask("time 15:00 tokyo")
        check("built-ins: a time on the same day says no day",
              sameDay?.hint.contains("day)") == false, "got \(String(describing: sameDay))")

        // Not a place, or nothing to convert: left to apps and the search.
        let notTimes = [
            "time", "time management", "time 15:00", "time 15 tokyo", "time 25:00 tokyo", "time tokyo in nowhere",
            // Zone cities and abbreviations that are plain words.
            "time christmas", "time easter", "time wake", "time cat", "time art", "time eat", "time pet", "time wet",
        ]
        for input in notTimes {
            check("built-ins: \(input) is not a time", ask(input) == nil, "got \(String(describing: ask(input)))")
        }

        check("built-ins: an island zone works by its identifier", ask("time pacific/easter") != nil)

        // The hint follows the Mac's language; the copy is always HH:mm.
        var american = context
        american.locale = Locale(identifier: "en_US")
        let usTime = BuiltIns.answer(for: "time tokyo", context: american)
        check("built-ins: a US Mac shows 10:05 PM but copies 22:05",
              usTime?.value == "22:05" && usTime?.hint.contains("PM") == true, "got \(String(describing: usTime))")
        let usConversion = BuiltIns.answer(for: "time 9am new york in paris", context: american)
        check("built-ins: a US Mac copies a converted time as 15:00",
              usConversion?.value == "15:00", "got \(String(describing: usConversion))")

        let clock = WorldClock.parseClock("9:30 pm london")
        check("built-ins: 9:30 pm reads as 21:30", clock.clock?.hour == 21 && clock.clock?.minute == 30 && clock.rest == "london")
        check("built-ins: 12pm reads as 12:00", WorldClock.parseClock("12pm").clock?.hour == 12)
        check("built-ins: 1530 is not a time", WorldClock.parseClock("1530").clock == nil)
        check("built-ins: 9 amsterdam is not a time", WorldClock.parseClock("9 amsterdam").clock == nil)
        check("built-ins: UTC+5:30 is named so",
              WorldClock.offsetName(TimeZone(secondsFromGMT: 19800)!, at: context.now) == "UTC+5:30")
        check("built-ins: UTC-3 is named so",
              WorldClock.offsetName(TimeZone(secondsFromGMT: -10800)!, at: context.now) == "UTC-3")
    }

    // MARK: uuid, now

    private static func uuidAndNow() {
        let uuid = ask("uuid")
        check("built-ins: uuid copies a new lowercase UUID",
              uuid?.value == "e621e1f8-c36c-495a-93fc-0c247a3e6e5f" && uuid?.kind == .uuid,
              "got \(String(describing: uuid))")
        check("built-ins: uuid with an argument is not the built-in", ask("uuid generator") == nil)
        check("built-ins: a real UUID is new each time",
              BuiltIns.answer(for: "uuid", context: .current)?.value != BuiltIns.answer(for: "uuid", context: .current)?.value)

        let cases: [(String, String)] = [
            ("now", "2026-11-03T14:05:09+01:00"),
            ("now UTC", "2026-11-03T13:05:09Z"),
            ("now unix", "1793711109"),
            ("now ms", "1793711109000"),
            ("now date", "2026-11-03"),
        ]
        for (input, expected) in cases {
            let answer = ask(input)
            check("built-ins: \(input) is \(expected)", answer?.value == expected, "got \(String(describing: answer))")
            check("built-ins: \(input) counts as a timestamp", answer?.kind == .timestamp)
        }
        check("built-ins: now playing is not the built-in", ask("now playing") == nil)
    }

    // MARK: Precedence

    private static func workflows(_ entries: [[String: Any]]) -> WorkflowSet? {
        let file: [String: Any] = ["workflows": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: file) else { return nil }
        return try? JSONDecoder().decode(WorkflowSet.self, from: data)
    }

    private static func precedence() {
        guard let set = workflows([
            ["keywords": ["uuid"], "title": "UUID site", "url": "https://example.com/uuid"],
            ["keywords": ["time"], "title": "Time search", "url": "https://example.com/time?q={query}"],
            ["keywords": ["now"], "title": "Now search", "url": "https://example.com/now?q={query}"],
        ]) else {
            check("built-ins: precedence test workflows decode", false)
            return
        }
        check("built-ins: a uuid workflow wins over the built-in",
              BuiltIns.answer(for: "uuid", workflows: set, context: context) == nil)
        check("built-ins: a time workflow with an argument wins",
              BuiltIns.answer(for: "time tokyo", workflows: set, context: context) == nil)
        check("built-ins: a keyword waiting for its argument wins",
              BuiltIns.answer(for: "now", workflows: set, context: context) == nil)
        check("built-ins: input no workflow takes still gets an answer",
              BuiltIns.answer(for: "= 1+1", workflows: set, context: context)?.value == "2")
        check("built-ins: the built-in workflows leave = 1+1 to the calculator",
              BuiltIns.answer(for: "= 1+1", workflows: WorkflowSet.builtIn, context: context)?.value == "2")
        check("built-ins: a calculation is counted under builtin.calculation",
              BuiltInKind.calculation.usageCounter.rawValue == "builtin.calculation")
    }
}
