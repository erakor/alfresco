// KeywordInput.swift
//
// Launcher input read as "/<keyword> [argument]", for the features that own
// a keyword (weather, calendar): the first word after Config.commandPrefix
// lowercased, and the rest.

import Foundation

struct KeywordInput {
    /// The first word, lowercased, without the command prefix.
    let keyword: String
    /// What follows it, trimmed; nil when nothing does.
    let argument: String?

    /// nil for empty input, or input without the command prefix (when one
    /// is set), since bare words are never a feature's keyword.
    init?(_ input: String) {
        guard let body = CommandInput.body(of: input) else { return nil }
        let parts = body.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return nil }
        keyword = first.lowercased()
        let rest = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        argument = rest.isEmpty ? nil : rest
    }
}
