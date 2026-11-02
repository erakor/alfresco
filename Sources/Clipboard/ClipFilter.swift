// ClipFilter.swift
//
// The clipboard history panel's search: which items match what is typed in
// its field. Runs on every keystroke, over texts of up to
// Config.clipboardMaxTextBytes each, so it avoids repeating work.

import Foundation

/// Matches items case-, accent- and width-insensitively: the item's texts and
/// the query are both folded (AppIndex.fold), then searched literally. Each
/// item's folded texts are made once and kept until `reset()`. Since a
/// literal match of a query is also a match of any text it contains, a query
/// that contains the previous one (typing on, at either end) only looks
/// through the previous query's matches.
struct ClipFilter {
    /// Folded search texts by item ID. An item's content never changes, so
    /// these stay valid for as long as the item exists.
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
        if let last, folded.range(of: last.query, options: .literal) != nil {
            candidates = last.items
        } else {
            candidates = items
        }
        let matching = candidates.filter { item in
            texts(of: item).contains { $0.range(of: folded, options: .literal) != nil }
        }
        #if SELFTEST
        lastSearchedCount = candidates.count
        #endif
        last = (folded, matching)
        return matching
    }

    /// The history changed: the next search looks through all of it again.
    mutating func historyDidChange() {
        last = nil
    }

    /// Frees the folded texts (the panel closed).
    mutating func reset() {
        last = nil
        searchTexts.removeAll()
    }

    private mutating func texts(of item: ClipItem) -> [String] {
        if let texts = searchTexts[item.id] { return texts }
        let texts = item.content.searchTexts
        searchTexts[item.id] = texts
        return texts
    }

    #if SELFTEST
    /// How many items the last search looked through.
    private(set) var lastSearchedCount = 0
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
