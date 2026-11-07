// Snippets.swift
//
// Pinned clipboard items with a short name (`sig`, `iban`) are snippets:
// typed in the launcher as `/snip sig`, Enter pastes the item into the app
// that was in front, as picking it in the clipboard history does. The name
// is given in the history panel with ⌘S (ClipboardController). The `/snip`
// workflow in workflows.json points at alfresco://snippet/{query}, run by
// AppDelegate; while it is typed, SnippetsView lists the snippets under the
// input.
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

/// Finding snippets in the history.
enum Snippets {
    /// The named items of `items` (pinned ones only), by name.
    static func all(in items: [ClipItem]) -> [ClipItem] {
        items.filter { $0.pinned && $0.snippetName != nil }
            .sorted { ($0.snippetName ?? "") < ($1.snippetName ?? "") }
    }

    /// The snippets whose name starts with `typed` (all of them for empty
    /// input), the exact name first, then by name.
    static func matches(_ typed: String, in items: [ClipItem]) -> [ClipItem] {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = all(in: items)
        guard !query.isEmpty else { return named }
        let starting = named.filter { $0.snippetName?.hasPrefix(query) == true }
        let exact = starting.filter { $0.snippetName == query }
        return exact + starting.filter { $0.snippetName != query }
    }

    /// The snippet `typed` names: the exact name, else the only one whose
    /// name starts with it. nil when there is none, or several and no exact
    /// one (Enter then beeps rather than guess).
    static func resolve(_ typed: String, in items: [ClipItem]) -> ClipItem? {
        let found = matches(typed, in: items)
        guard let first = found.first, !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if first.snippetName == typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() { return first }
        return found.count == 1 ? first : nil
    }

    /// What `/snip <typed>` would do, for the launcher's hint.
    static func hint(for typed: String, in items: [ClipItem]) -> String {
        if let item = resolve(typed, in: items), let name = item.snippetName {
            return "↩ Paste \(name)"
        }
        let count = matches(typed, in: items).count
        let shown = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return count == 0 ? "No snippet named \(shown)" : "\(count) snippets start with \(shown)"
    }

    /// One line describing a snippet's content, for the launcher's list:
    /// the first non-blank line of text, an image's size, or file names.
    static func preview(of content: ClipContent, maxLength: Int = 120) -> String {
        switch content {
        case .text(let text):
            // Only the start of a long text: never split the whole of it.
            let head = text.prefix(maxLength * 4)
            let line = head.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            return line.count > maxLength ? String(line.prefix(maxLength - 1)) + "…" : line
        case .image(let image):
            return "Image: \(image.dimensions)"
        case .files(let paths):
            let names = paths.map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
        }
    }
}
