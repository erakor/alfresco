// KeywordInput.swift
//
// Launcher input read as "<keyword> [argument]": the first word lowercased,
// and the rest. The built-ins read bare input (`time tokyo`); the features
// that own a workflow keyword (weather, calendar) read it after
// Config.commandPrefix with `init(command:)` (`/weather paris`).

import Foundation

struct KeywordInput {
    /// The first word, lowercased.
    let keyword: String
    /// What follows it, trimmed; nil when nothing does.
    let argument: String?

    /// `input` as typed. nil for empty input.
    init?(_ input: String) {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return nil }
        keyword = first.lowercased()
        let rest = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        argument = rest.isEmpty ? nil : rest
    }

    /// `input` after the command prefix (CommandInput.body). nil for bare
    /// input when a prefix is set, since a bare word is never a workflow
    /// keyword, and for the prefix alone.
    init?(command input: String) {
        guard let body = CommandInput.body(of: input) else { return nil }
        self.init(body)
    }
}
