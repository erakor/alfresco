// Snippets.swift
//
// Pinned clipboard items with a short name (`sig`, `iban`) are snippets:
// typed in the launcher as `/snip sig`, Enter pastes the item into the app
// that was in front, as picking it in the clipboard history does. The name
// is given in the history panel with ⌘S (ClipboardController). The `/snip`
// workflow in workflows.json points at alfresco://snippet/{query}, run by
// AppDelegate; while it is typed, SnippetsView lists what SnippetSearch
// finds under the input.
//
// Everything here is pure (no AppKit), so the self-test checks it.

import Foundation

/// The rules for a snippet name.
enum SnippetName {
    /// Names are short words typed after `/snip`.
    static let maxLength = 32

    /// `raw` as stored and matched: trimmed and lowercased. nil when empty,
    /// longer than maxLength, or holding a space or a character a URL path
    /// can't carry back unchanged (`/`, `?`, `#`, `%`).
    static func normalize(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name.count <= maxLength,
              !name.contains(where: { $0.isWhitespace || $0.isNewline || "/?#%".contains($0) })
        else { return nil }
        return name
    }
}

/// alfresco://snippet/<name>, the `/snip` workflow's URL.
enum SnippetCommand {
    static let feature = "snippet"

    /// The typed name in an alfresco://snippet/<name> URL; nil for another
    /// URL or no name.
    static func name(of url: URL) -> String? {
        guard let action = InternalURL.action(of: url, feature: feature), !action.isEmpty else { return nil }
        return action
    }

    /// Whether a workflow's URL template (`alfresco://snippet/{query}`)
    /// runs a snippet.
    static func isSnippetTemplate(_ template: String) -> Bool {
        let filled = template.replacingOccurrences(of: "{query}", with: "x")
        return URL(string: filled).flatMap(InternalURL.feature(of:)) == feature
    }
}

/// What `/snip <typed>` finds in the history: worked out once per change of
/// the launcher's input, then read by the list, the hint and the self-test.
struct SnippetSearch {
    /// What was typed after the keyword, as names are stored (trimmed and
    /// lowercased); empty for the keyword alone.
    let query: String
    /// The snippets whose name starts with `query`, by name (so an exact
    /// name, a prefix of the others, comes first); all of them for "".
    let found: [ClipItem]
    /// The one Enter pastes: the exact name, else the only one starting with
    /// `query`. nil when there is none, or several and no exact one (Enter
    /// then beeps rather than guess), and for "".
    let resolved: ClipItem?
    /// Whether the history has any snippet at all.
    let hasSnippets: Bool

    /// `items` is the history, pinned items first (ClipboardStore.items):
    /// only pinned items carry a name, so only those are looked through.
    init(typed: String, items: [ClipItem]) {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.query = query
        let named = items.prefix(while: \.pinned)
            .filter { $0.snippetName != nil }
            .sorted { ($0.snippetName ?? "") < ($1.snippetName ?? "") }
        hasSnippets = !named.isEmpty
        found = query.isEmpty ? named : named.filter { $0.snippetName?.hasPrefix(query) == true }
        if query.isEmpty {
            resolved = nil
        } else if let first = found.first, first.snippetName == query || found.count == 1 {
            resolved = first
        } else {
            resolved = nil
        }
    }

    /// What Enter would do, for the launcher's hint.
    var hint: String {
        if let name = resolved?.snippetName { return "↩ Paste \(name)" }
        return found.isEmpty ? "No snippet named \(query)" : "\(found.count) snippets start with \(query)"
    }
}
