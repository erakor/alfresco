// BuiltIns.swift
//
// Launcher answers the app works out itself instead of opening a URL: a
// calculator and unit converter (`= 3*14`, `= 10 km in mi`), world clocks
// (`time tokyo`, `time 15:00 in tokyo`), and a fresh UUID or timestamp
// (`uuid`, `now`). The hint shows the answer and Enter copies it. They only
// take input no workflow takes, so a workflows.json keyword always wins.

import Foundation

/// Which built-in answered; each is counted in the usage stats.
enum BuiltInKind: Sendable {
    case calculation, conversion, time, uuid, timestamp

    var usageCounter: UsageCounter {
        switch self {
        case .calculation: return .builtInCalculation
        case .conversion: return .builtInConversion
        case .time: return .builtInTime
        case .uuid: return .builtInUUID
        case .timestamp: return .builtInTimestamp
        }
    }

    /// The launcher's icon while it answers.
    var symbolName: String {
        switch self {
        case .calculation: return "equal.circle"
        case .conversion: return "arrow.left.arrow.right"
        case .time: return "clock"
        case .uuid: return "number"
        case .timestamp: return "calendar.badge.clock"
        }
    }
}

/// What a built-in makes of the launcher input.
enum BuiltInAnswer: Equatable, Sendable {
    /// Enter copies `value`. `hint` is the whole hint line ("42  ↩ Copy"),
    /// `detail` its tooltip.
    case result(kind: BuiltInKind, hint: String, value: String, detail: String?)
    /// The input is the built-in's, but has no answer (yet): the hint shows
    /// `message` and Enter beeps, rather than searching for "= 3*".
    case incomplete(kind: BuiltInKind, message: String)

    var kind: BuiltInKind {
        switch self {
        case .result(let kind, _, _, _), .incomplete(let kind, _): return kind
        }
    }

    var hint: String {
        switch self {
        case .result(_, let hint, _, _): return hint
        case .incomplete(_, let message): return message
        }
    }

    var detail: String? {
        switch self {
        case .result(_, _, _, let detail): return detail
        case .incomplete(_, let message): return message
        }
    }

    /// What Enter copies; nil while incomplete.
    var value: String? {
        if case .result(_, _, let value, _) = self { return value }
        return nil
    }
}

/// What the answers depend on besides the input, so the self-test can pin it.
struct BuiltInContext: Sendable {
    var now: Date
    var timeZone: TimeZone
    var locale: Locale
    var makeUUID: @Sendable () -> UUID

    static var current: BuiltInContext {
        BuiltInContext(now: Date(), timeZone: .current, locale: .current, makeUUID: { UUID() })
    }
}

enum BuiltIns {
    /// The answer for launcher input, or nil when no built-in takes it.
    /// Input a workflow takes (or a keyword waiting for its argument) is
    /// never a built-in's, so `workflows` always wins.
    static func answer(for input: String, workflows: WorkflowSet, context: BuiltInContext = .current) -> BuiltInAnswer? {
        guard workflows.workflowAwaitingArgument(input) == nil,
              CommandParser.isUnmatched(input, using: workflows)
        else { return nil }
        return answer(for: input, context: context)
    }

    /// The answer for `input`, whatever workflows.json holds.
    static func answer(for input: String, context: BuiltInContext) -> BuiltInAnswer? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix = Config.calculatorPrefix, !prefix.isEmpty, input.hasPrefix(prefix) {
            return calculate(String(input.dropFirst(prefix.count)))
        }
        guard let parts = KeywordInput(input) else { return nil }
        if parts.keyword == Config.timeKeyword {
            // `time` alone is left to apps (Time Machine) and the search.
            return parts.argument.flatMap { WorldClock.answer(for: $0, context: context) }
        }
        if parts.keyword == Config.uuidKeyword, parts.argument == nil {
            return .result(
                kind: .uuid, hint: "↩ Copy a new UUID",
                value: context.makeUUID().uuidString.lowercased(), detail: nil
            )
        }
        if parts.keyword == Config.timestampKeyword {
            return timestamp(parts.argument.map { AppIndex.fold($0) }, context: context)
        }
        return nil
    }

    // MARK: Calculator

    private static func calculate(_ text: String) -> BuiltInAnswer {
        let text = text.trimmingCharacters(in: .whitespaces)
        let prefix = Config.calculatorPrefix ?? ""
        guard !text.isEmpty else {
            return .incomplete(kind: .calculation, message: "Calculate (\(prefix) 3*14) or convert (\(prefix) 10 km in mi)")
        }
        // "10 km in", typed so far (the input is trimmed, so " in " has lost
        // its last space).
        let lowercased = " " + text.lowercased()
        if UnitConverter.separators.contains(where: { separator in
            let typed = separator.hasSuffix(" ") ? String(separator.dropLast()) : separator
            return lowercased.hasSuffix(typed)
        }) {
            return .incomplete(kind: .conversion, message: "Type the unit to convert to")
        }
        if let conversion = UnitConverter.convert(text) {
            switch conversion {
            case .success(let conversion):
                let value = Calculator.format(conversion.value)
                return .result(
                    kind: .conversion, hint: "\(value) \(conversion.to.symbol)  ↩ Copy", value: value,
                    detail: "\(Calculator.format(conversion.amount)) \(conversion.from.symbol) = \(value) \(conversion.to.symbol)"
                )
            case .failure(let error):
                return .incomplete(kind: .conversion, message: error.message)
            }
        }
        do {
            let value = try Calculator.format(Calculator.evaluate(text))
            return .result(kind: .calculation, hint: "\(value)  ↩ Copy", value: value, detail: "\(text) = \(value)")
        } catch CalculatorError.unknownName(let name) where UnitConverter.unit(named: name) != nil {
            // "= 10 km": a unit, with nothing to convert it to.
            return .incomplete(kind: .conversion, message: "Convert with \(prefix) \(text) in <unit>")
        } catch {
            return .incomplete(kind: .calculation, message: (error as? CalculatorError)?.message ?? "No result")
        }
    }

    // MARK: Timestamp

    /// `now` (ISO 8601 with the local offset), `now utc`, `now unix`
    /// (seconds), `now ms` (milliseconds) or `now date`. Anything else after
    /// `now` is left to the search.
    private static func timestamp(_ argument: String?, context: BuiltInContext) -> BuiltInAnswer? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = context.timeZone
        let value: String
        switch argument {
        case nil:
            value = formatter.string(from: context.now)
        case "utc"?, "z"?:
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            value = formatter.string(from: context.now)
        case "unix"?, "epoch"?:
            value = String(Int64((context.now.timeIntervalSince1970).rounded(.down)))
        case "ms"?:
            value = String(Int64((context.now.timeIntervalSince1970 * 1000).rounded(.down)))
        case "date"?:
            formatter.formatOptions = [.withFullDate]
            value = formatter.string(from: context.now)
        default:
            return nil
        }
        let keyword = Config.timestampKeyword ?? "now"
        return .result(
            kind: .timestamp, hint: "\(value)  ↩ Copy", value: value,
            detail: "\(keyword), \(keyword) utc, \(keyword) unix, \(keyword) ms, \(keyword) date"
        )
    }
}
