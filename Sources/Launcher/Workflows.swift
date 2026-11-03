// Workflows.swift
//
// The workflows.json model (Workflow, WorkflowSet, ArgumentTransform), the
// WorkflowStore that reloads it, CommandInput, which reads the command
// prefix (`/pr 12`), and CommandParser, which turns launcher input into a URL.

import Foundation

// MARK: - Command prefix

/// Launcher input read as a command: what follows Config.commandPrefix.
/// Keywords are stored without the prefix; this is the one place that adds
/// or removes it. It is used by several features but lives here, not in
/// Sources/Shared, because .claude/skills/add-workflow/scripts/check.sh
/// compiles Workflows.swift on its own (with WorkflowCheck.swift and a stub
/// Config): moving it out would break that script.
enum CommandInput {
    /// Whether `input` starts with the prefix, so it is a command (known or
    /// not) and never goes to apps, built-ins or the fallback search. Always
    /// false with no prefix.
    static func isCommand(_ input: String) -> Bool {
        guard let prefix = Config.commandPrefix, !prefix.isEmpty else { return false }
        return input.drop(while: \.isWhitespace).hasPrefix(prefix)
    }

    /// `input` trimmed and without the prefix ("/pr 12" is "pr 12", "/" is
    /// ""); nil when a prefix is set and `input` doesn't start with it, since
    /// bare words are never commands, or when a space follows the prefix:
    /// `/ zz` is a stray slash, not `/zz`, so it runs nothing (isCommand
    /// still holds, so Enter beeps). With no prefix, `input` trimmed.
    static func body(of input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = Config.commandPrefix, !prefix.isEmpty else { return trimmed }
        guard trimmed.hasPrefix(prefix) else { return nil }
        let body = trimmed.dropFirst(prefix.count)
        if body.first?.isWhitespace == true { return nil }
        return String(body)
    }

    /// A keyword as it is typed: "/pr".
    static func typed(_ keyword: String) -> String {
        (Config.commandPrefix ?? "") + keyword
    }

    /// `keyword` from workflows.json without a leading prefix, so a file
    /// that writes "/pr" still means `/pr`, not `//pr`.
    static func stored(_ keyword: String) -> String {
        guard let prefix = Config.commandPrefix, !prefix.isEmpty, keyword.hasPrefix(prefix) else { return keyword }
        return String(keyword.dropFirst(prefix.count))
    }
}

// MARK: - Workflows

/// A step applied to the argument before it is put into the URL. Written in
/// JSON as a string: "uppercase", "lowercase", "trim",
/// "stripPrefix:<text>" or "stripSuffix:<text>".
enum ArgumentTransform: Decodable, Sendable {
    case uppercase
    case lowercase
    case trim
    case stripPrefix(String)
    case stripSuffix(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        var name = raw
        var value = ""
        if let colon = raw.firstIndex(of: ":") {
            name = String(raw[..<colon])
            value = String(raw[raw.index(after: colon)...])
        }

        switch (name, value.isEmpty) {
        case ("uppercase", true): self = .uppercase
        case ("lowercase", true): self = .lowercase
        case ("trim", true): self = .trim
        case ("stripPrefix", false): self = .stripPrefix(value)
        case ("stripSuffix", false): self = .stripSuffix(value)
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown transform \"\(raw)\" (use uppercase, lowercase, trim, stripPrefix:<text> or stripSuffix:<text>)"
            )
        }
    }

    func apply(to value: String) -> String {
        switch self {
        case .uppercase: return value.uppercased()
        case .lowercase: return value.lowercased()
        case .trim: return value.trimmingCharacters(in: .whitespaces)
        case .stripPrefix(let prefix): return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
        case .stripSuffix(let suffix): return value.hasSuffix(suffix) ? String(value.dropLast(suffix.count)) : value
        }
    }
}

/// A keyword that expands into a URL. `{query}` in `url` is replaced with the
/// percent-encoded argument; a `url` without `{query}` is opened by typing
/// the keyword alone. One keyword can have both forms as two workflows.
/// `description` is optional help text. `preview` is an optional URL, filled
/// in like `url`, whose short plain-text answer is shown in the hint while
/// typing (e.g. the weather).
struct Workflow: Decodable, Sendable {
    let keywords: [String]
    let title: String
    let url: String
    /// Shown while the keyword is typed without its argument, and in the
    /// menu bar's Workflows submenu. Written as "description" in JSON.
    let help: String?
    let transforms: [ArgumentTransform]
    /// https URL template fetched while the input matches this workflow;
    /// the first line of its plain-text response is shown in the hint. nil
    /// when the file's was refused (see previewRefusal).
    let preview: String?
    /// Why this workflow can't be used (a url scheme outside
    /// Config.workflowURLSchemes), or nil. WorkflowSet leaves such a
    /// workflow out and reports it, rather than refusing the whole file: one
    /// old entry shouldn't take every keyword down with it.
    let refusal: String?
    /// Why the file's preview was left out (not https, or {query} in it but
    /// not in url), or nil. Only the preview goes: the workflow still runs,
    /// so its input doesn't fall through to the fallback search instead.
    let previewRefusal: String?

    var takesArgument: Bool { url.contains("{query}") }

    private enum CodingKeys: String, CodingKey {
        case keywords, title, url, transforms, preview
        case help = "description"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)?
            .map { CommandInput.stored($0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? []
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        help = try container.decodeIfPresent(String.self, forKey: .help)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        transforms = try container.decodeIfPresent([ArgumentTransform].self, forKey: .transforms) ?? []
        let preview = try container.decodeIfPresent(String.self, forKey: .preview)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let preview, Self.scheme(of: preview) != "https" {
            // https only: what is typed after the keyword goes into it.
            previewRefusal = "preview must be an https URL"
        } else if let preview, preview.contains("{query}"), !url.contains("{query}") {
            previewRefusal = "preview uses {query} but url does not"
        } else {
            previewRefusal = nil
        }
        self.preview = previewRefusal == nil ? preview : nil

        if keywords.contains(where: \.isEmpty) {
            // Also "/" alone, which CommandInput.stored empties.
            throw DecodingError.dataCorruptedError(
                forKey: .keywords, in: container,
                debugDescription: "keywords can't be empty (or just \"\(Config.commandPrefix ?? "")\")"
            )
        }
        if keywords.contains(where: { $0.contains(where: \.isWhitespace) }) {
            throw DecodingError.dataCorruptedError(
                forKey: .keywords, in: container,
                debugDescription: "keywords must be single words"
            )
        }
        if let scheme = Self.scheme(of: url), Config.workflowURLSchemes.contains(scheme) {
            refusal = nil
        } else {
            let allowed = Config.workflowURLSchemes.sorted().map { "\($0):" }.joined(separator: ", ")
            refusal = "url must start with one of \(allowed) (see Config.workflowURLSchemes)"
        }
    }

    func prepare(_ argument: String) -> String {
        transforms.reduce(argument) { $1.apply(to: $0) }
    }

    /// The scheme of a URL template, lowercased: what comes before its first
    /// ":". nil when there is none, or when `{query}` comes before it, so what
    /// is typed can never choose the scheme.
    static func scheme(of template: String) -> String? {
        guard let colon = template.firstIndex(of: ":") else { return nil }
        let scheme = template[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        return scheme.lowercased()
    }
}

struct WorkflowSet: Decodable, Sendable {
    /// The usable workflows, in file order.
    let workflows: [Workflow]
    /// Where input no workflow takes goes: the file's, else the built-in
    /// Google search when the file has none. nil when the file's was refused:
    /// that input then goes nowhere (the launcher beeps) rather than to a
    /// search the user didn't choose.
    let fallback: Workflow?
    /// Every keyword of `workflows`.
    let keywords: Set<String>
    /// What was left out (see Workflow.refusal and previewRefusal), one
    /// message each, e.g. "\"Notes\": url must start with one of ...".
    /// WorkflowStore reports them; the rest of the file is used.
    let refused: [String]

    private enum CodingKeys: String, CodingKey { case workflows, fallback }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let all = try container.decode([Workflow].self, forKey: .workflows)
        if let index = all.firstIndex(where: { $0.keywords.isEmpty }) {
            throw DecodingError.dataCorruptedError(
                forKey: .workflows, in: container,
                debugDescription: "workflow #\(index + 1) (\(all[index].title)) has no keywords"
            )
        }
        var refused: [String] = []
        for workflow in all {
            if let refusal = workflow.refusal {
                refused.append("\"\(workflow.title)\": \(refusal)")
            } else if let refusal = workflow.previewRefusal {
                refused.append("\"\(workflow.title)\": \(refusal) (its preview is left out)")
            }
        }
        workflows = all.filter { $0.refusal == nil }
        keywords = Set(workflows.flatMap(\.keywords))

        let decodedFallback = try container.decodeIfPresent(Workflow.self, forKey: .fallback)
        if let decodedFallback {
            if !decodedFallback.takesArgument {
                throw DecodingError.dataCorruptedError(
                    forKey: .fallback, in: container,
                    debugDescription: "fallback url must contain {query}"
                )
            }
            // A fallback preview would send everything typed to that server.
            if decodedFallback.preview != nil || decodedFallback.previewRefusal != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .fallback, in: container,
                    debugDescription: "fallback cannot have a preview"
                )
            }
        }
        if let refusal = decodedFallback?.refusal {
            // Fail closed: never send what is typed to a search the user didn't pick.
            refused.append("fallback: \(refusal); input no keyword takes goes nowhere until it is fixed")
            fallback = nil
        } else {
            fallback = decodedFallback ?? Self.builtIn.fallback
        }
        self.refused = refused
    }

    // swiftlint:disable:next force_try
    static let builtIn = try! JSONDecoder().decode(WorkflowSet.self, from: Data(Config.defaultWorkflowsJSON.utf8))

    /// The first workflow with this keyword that fits the input: one with
    /// `{query}` when an argument was typed, one without it when the keyword
    /// was typed alone. A keyword can therefore be listed twice, once per
    /// form (e.g. "weather" and "weather paris").
    func workflow(for keyword: String, withArgument: Bool) -> Workflow? {
        let keyword = keyword.lowercased()
        return workflows.first { $0.keywords.contains(keyword) && $0.takesArgument == withArgument }
    }

    /// The workflow whose keyword is the whole input, when it still needs an
    /// argument (e.g. just "/pr") and no workflow takes that keyword alone.
    /// Enter does nothing then, and the hint shows the workflow's help instead.
    func workflowAwaitingArgument(_ input: String) -> Workflow? {
        guard let input = CommandInput.body(of: input), !input.isEmpty,
              workflow(for: input, withArgument: false) == nil
        else { return nil }
        return workflow(for: input, withArgument: true)
    }

    /// Whether `input` asks for the list of every command: the prefix alone,
    /// or `/help` while no workflow uses that keyword. Never with no prefix.
    func listsAllCommands(_ input: String) -> Bool {
        guard let prefix = Config.commandPrefix, !prefix.isEmpty,
              let body = CommandInput.body(of: input)?.lowercased()
        else { return false }
        return body.isEmpty || (body == Config.commandListKeyword.lowercased() && !keywords.contains(body))
    }

    /// Workflows whose keyword starts with what is typed (after the command
    /// prefix), for the list under the launcher input. Only while a single
    /// word is typed, and not when it already is every match's whole keyword
    /// (nothing left to complete). Exact matches come first, then file
    /// order. One row per workflow, with its first matching keyword, so
    /// "weather" and "weather paris" are two. A keyword is only offered for
    /// the workflow it would actually run: an earlier workflow of the same
    /// form with that keyword shadows it. Among a workflow's aliases, one
    /// equal to the typed word wins. `listsAllCommands` input gets every
    /// workflow that has a usable keyword.
    func suggestions(for input: String) -> [Suggestion] {
        let listsAll = listsAllCommands(input)
        guard let body = CommandInput.body(of: input) else { return [] }
        let prefix = listsAll ? "" : body.lowercased()
        guard listsAll || !prefix.isEmpty, !prefix.contains(where: \.isWhitespace) else { return [] }
        let matches = workflows.indices.compactMap { index -> Suggestion? in
            let workflow = workflows[index]
            let usable = workflow.keywords.filter { keyword in
                keyword.hasPrefix(prefix) && workflows.firstIndex {
                    $0.keywords.contains(keyword) && $0.takesArgument == workflow.takesArgument
                } == index
            }
            let keyword = usable.contains(prefix) ? prefix : usable.first
            return keyword.map { Suggestion(keyword: $0, workflow: workflow) }
        }
        if listsAll { return matches }
        let exact = matches.filter { $0.keyword == prefix }
        guard exact.count < matches.count else { return [] }
        return exact + matches.filter { $0.keyword != prefix }
    }
}

/// A row in the launcher's suggestion list.
struct Suggestion: Sendable {
    /// As stored, without the command prefix.
    let keyword: String
    let workflow: Workflow

    /// What Tab puts in the field: the keyword with its prefix, plus a space
    /// when the workflow needs an argument, so typing can go straight on.
    var completion: String {
        let typed = CommandInput.typed(keyword)
        return workflow.takesArgument ? typed + " " : typed
    }
}

/// Owns workflows.json: finds it, reloads it when its modification date
/// changes, and keeps the last good version if an edit breaks it. Only used
/// from the main thread.
final class WorkflowStore {
    let fileURL: URL
    /// Only the ~/.config fallback is created when missing; a configured path
    /// that has gone missing is reported instead of silently recreated.
    private let createsMissingFile: Bool
    private(set) var current = WorkflowSet.builtIn
    /// Why the file on disk could not be used, if it could not.
    private(set) var loadError: String?
    private var loadedModificationDate: Date?

    init(fileURL: URL = Config.workflowsSource.url, createsMissingFile: Bool = Config.workflowsSource.isFallback) {
        self.fileURL = fileURL
        self.createsMissingFile = createsMissingFile
        reloadIfNeeded()
    }

    /// Writes the default file if it is the ~/.config fallback and missing.
    func ensureFileExists() {
        let fileManager = FileManager.default
        guard createsMissingFile, !fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(Config.defaultWorkflowsJSON.utf8).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Launcher: could not create %@: %@", fileURL.path, error.localizedDescription)
        }
    }

    /// Cheap enough to call every time the launcher opens: it only parses the
    /// file when its modification date differs from the last load.
    func reloadIfNeeded() {
        ensureFileExists()
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modified = attributes?[.modificationDate] as? Date
        guard modified == nil || modified != loadedModificationDate else { return }
        loadedModificationDate = modified

        do {
            let data = try Data(contentsOf: fileURL)
            current = try JSONDecoder().decode(WorkflowSet.self, from: data)
            // The file is used without its refused workflows, which are reported.
            loadError = current.refused.isEmpty ? nil : "left out " + current.refused.joined(separator: "; ")
            if let loadError { NSLog("Launcher: %@: %@", fileURL.path, loadError) }
        } catch {
            loadError = Self.describe(error)
            NSLog("Launcher: ignoring %@: %@", fileURL.path, loadError ?? "")
        }
    }

    /// A decoding error as the one line shown in the hint area (and printed
    /// by `Launcher --check`).
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func location(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
            }.joined()
            return path.isEmpty ? "" : " at \(path)"
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \"\(key.stringValue)\"\(location(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(context.debugDescription)\(location(context))"
        case .dataCorrupted(let context):
            if let underlying = context.underlyingError as NSError?,
               let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                return detail
            }
            return "\(context.debugDescription)\(location(context))"
        @unknown default:
            return error.localizedDescription
        }
    }
}

// MARK: - Command parsing

/// Which part of workflows.json produced a command.
enum CommandSource: Equatable, Sendable {
    /// `keyword` is the workflow's first keyword, whichever one was typed.
    case workflow(keyword: String, withArgument: Bool)
    case fallback
}

struct Command {
    let url: URL
    let label: String
    let source: CommandSource
    /// The workflow's preview URL, filled in with the same argument.
    var preview: URL?
    /// No keyword matched; this is the fallback search. Installed apps whose
    /// name matches the input take precedence over it.
    var isFallback: Bool { source == .fallback }
}

enum CommandParser {
    /// RFC 3986 unreserved characters; everything else gets percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Parses `/<keyword> [argument]`, falling back to the fallback workflow
    /// for input without the command prefix. nil for empty input, for
    /// command input no workflow takes (`/`, `/help`, `/nope`: never
    /// searched for), or for other input no workflow takes when there is no
    /// fallback (WorkflowSet.fallback).
    static func parse(_ raw: String, using set: WorkflowSet) -> Command? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let command = workflowCommand(input, using: set) { return command }
        guard !CommandInput.isCommand(input) else { return nil }
        return fallbackCommand(input, using: set)
    }

    /// The fallback search for the whole input, prefix included, whatever
    /// workflow would take it: what ⌘↩ runs for command input (`/r/swift`).
    /// nil for empty input or when there is no fallback.
    static func fallbackCommand(_ raw: String, using set: WorkflowSet) -> Command? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let fallback = set.fallback,
              let url = expand(fallback.url, with: fallback.prepare(input))
        else { return nil }
        return Command(url: url, label: fallback.title, source: .fallback)
    }

    /// Whether the input is something no workflow takes, so it goes to the
    /// fallback search, if there is one. Installed apps and built-ins only
    /// take such input. Command input (`/…`) never is, known or not.
    static func isUnmatched(_ raw: String, using set: WorkflowSet) -> Bool {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !input.isEmpty && !CommandInput.isCommand(input) && workflowCommand(input, using: set) == nil
    }

    /// The workflow command for trimmed, non-empty input, if a workflow
    /// takes it: only input starting with the command prefix, when there is one.
    private static func workflowCommand(_ raw: String, using set: WorkflowSet) -> Command? {
        guard let input = CommandInput.body(of: raw), !input.isEmpty else { return nil }
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let keyword = String(parts[0])
        if parts.count == 2, let workflow = set.workflow(for: keyword, withArgument: true) {
            let argument = workflow.prepare(parts[1].trimmingCharacters(in: .whitespaces))
            if !argument.isEmpty, let url = expand(workflow.url, with: argument) {
                return Command(
                    url: url, label: "\(workflow.title) \(argument)",
                    source: .workflow(keyword: workflow.keywords.first ?? keyword.lowercased(), withArgument: true),
                    preview: workflow.preview.flatMap { expand($0, with: argument) }
                )
            }
        } else if parts.count == 1, let workflow = set.workflow(for: keyword, withArgument: false),
                  let url = URL(string: workflow.url) {
            return Command(
                url: url, label: workflow.title,
                source: .workflow(keyword: workflow.keywords.first ?? keyword.lowercased(), withArgument: false),
                preview: workflow.preview.flatMap { URL(string: $0) }
            )
        }
        return nil
    }

    private static func expand(_ template: String, with argument: String) -> URL? {
        guard let encoded = argument.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }
}
