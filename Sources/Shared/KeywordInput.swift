// KeywordInput.swift
//
// Launcher input read as "<keyword> [argument]", for the features that own
// a keyword (weather, calendar): the first word lowercased, and the rest.

import Foundation

struct KeywordInput {
    /// The first word, lowercased.
    let keyword: String
    /// What follows it, trimmed; nil when nothing does.
    let argument: String?

    /// nil for empty input.
    init?(_ input: String) {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return nil }
        keyword = first.lowercased()
        let rest = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        argument = rest.isEmpty ? nil : rest
    }
}
