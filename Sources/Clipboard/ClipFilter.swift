// ClipFilter.swift
//
// The clipboard history panel's search: which items match what is typed in
// its field. Runs on every keystroke, over texts of up to
// Config.clipboardMaxTextBytes each, so it avoids repeating work.

import Foundation

/// Matches items case-, accent- and width-insensitively: the item's texts and
/// the query are both folded (AppIndex.fold), then searched for whole
/// characters (`contains`). Each item's folded texts are made the first time
/// it is searched and kept until it leaves the history, since its content
/// never changes. Since a match of a query is also a match of any text it
/// contains, a query that contains the previous one (typing on, at either
/// end) only looks through the previous query's matches.
struct ClipFilter {
    /// Folded search texts by item ID.
    private var searchTexts: [UUID: [String]] = [:]
    /// The last folded query and what it matched, to narrow from.
    private var last: (query: String, items: [ClipItem])?

    /// The items of `items` (in their order) that match `query`.
    mutating func items(matching query: String, in items: [ClipItem]) -> [ClipItem] {
        let folded = AppIndex.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty else {
            last = nil
            return items
        }
        let candidates: [ClipItem]
        if let last, Self.contains(folded, last.query) {
            candidates = last.items
        } else {
            candidates = items
        }
        let matching = candidates.filter { item in
            texts(of: item).contains { Self.contains($0, folded) }
        }
        #if SELFTEST
        lastSearchedCount = candidates.count
        #endif
        last = (folded, matching)
        return matching
    }

    /// The history is now `items`: the next search looks through all of it
    /// again, and the folded texts of items no longer in it are dropped.
    mutating func historyDidChange(_ items: [ClipItem]) {
        last = nil
        let ids = Set(items.map(\.id))
        searchTexts = searchTexts.filter { ids.contains($0.key) }
    }

    /// The panel closed: the next opening starts from an empty field. The
    /// folded texts stay for the next search.
    mutating func forgetQuery() {
        last = nil
    }

    private mutating func texts(of item: ClipItem) -> [String] {
        if let texts = searchTexts[item.id] { return texts }
        let texts = item.content.searchTexts
        searchTexts[item.id] = texts
        return texts
    }

    /// Whether `text` contains `query` as whole characters: a literal search
    /// (fast, and makes no copies) whose match must start and end on
    /// character boundaries, so "👍" doesn't match inside "👍🏽".
    static func contains(_ text: String, _ query: String) -> Bool {
        var start = text.startIndex
        while let found = text.range(of: query, options: .literal, range: start..<text.endIndex) {
            if found.lowerBound.samePosition(in: text) != nil, found.upperBound.samePosition(in: text) != nil {
                return true
            }
            // A literal match starts on a scalar, so the next one is a
            // valid place to look again.
            start = text.unicodeScalars.index(after: found.lowerBound)
        }
        return false
    }

    #if SELFTEST
    /// How many items the last search looked through.
    private(set) var lastSearchedCount = 0
    /// How many items have folded texts kept.
    var foldedCountForSelfTest: Int { searchTexts.count }
    #endif
}

extension ClipContent {
    /// What the history panel's search looks in, folded (AppIndex.fold).
    var searchTexts: [String] {
        switch self {
        case .text(let text):
            return [AppIndex.fold(text)]
        case .image(let image):
            // Both the displayed "1920 × 1080" and a typed "1920x1080" match.
            return [AppIndex.fold("Image: \(image.dimensions) \(image.pixelWidth)x\(image.pixelHeight)")]
        case .files(let paths):
            return paths.map { AppIndex.fold($0) }
        }
    }
}
