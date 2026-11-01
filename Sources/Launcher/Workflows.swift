// Workflows.swift
//
// The workflows.json model (Workflow, WorkflowSet, ArgumentTransform), the
// WorkflowStore that reloads it, and CommandParser, which turns launcher
// input into a URL.

import Foundation

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
    /// http(s) URL template fetched while the input matches this workflow;
    /// the first line of its plain-text response is shown in the hint.
    let preview: String?

    var takesArgument: Bool { url.contains("{query}") }

    private enum CodingKeys: String, CodingKey {
        case keywords, title, url, transforms, preview
        case help = "description"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)?
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        help = try container.decodeIfPresent(String.self, forKey: .help)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        transforms = try container.decodeIfPresent([ArgumentTransform].self, forKey: .transforms) ?? []
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        if keywords.contains(where: { $0.isEmpty || $0.contains(where: \.isWhitespace) }) {
            throw DecodingError.dataCorruptedError(
                forKey: .keywords, in: container,
                debugDescription: "keywords must be single words"
            )
        }
        if let preview {
            let scheme = URL(string: preview.replacingOccurrences(of: "{query}", with: "x"))?.scheme?.lowercased()
            if scheme != "https" && scheme != "http" {
                throw DecodingError.dataCorruptedError(
                    forKey: .preview, in: container,
                    debugDescription: "preview must be an http(s) URL"
                )
            }
            if preview.contains("{query}") && !takesArgument {
                throw DecodingError.dataCorruptedError(
                    forKey: .preview, in: container,
                    debugDescription: "preview uses {query} but url does not"
                )
            }
        }
    }

    func prepare(_ argument: String) -> String {
        transforms.reduce(argument) { $1.apply(to: $0) }
    }
}

struct WorkflowSet: Decodable, Sendable {
    let workflows: [Workflow]
    let fallback: Workflow

    private enum CodingKeys: String, CodingKey { case workflows, fallback }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflows = try container.decode([Workflow].self, forKey: .workflows)
        fallback = try container.decodeIfPresent(Workflow.self, forKey: .fallback) ?? Self.builtIn.fallback

        if let index = workflows.firstIndex(where: { $0.keywords.isEmpty }) {
            throw DecodingError.dataCorruptedError(
                forKey: .workflows, in: container,
                debugDescription: "workflow #\(index + 1) (\(workflows[index].title)) has no keywords"
            )
        }
        if !fallback.takesArgument {
            throw DecodingError.dataCorruptedError(
                forKey: .fallback, in: container,
                debugDescription: "fallback url must contain {query}"
            )
        }
        // A fallback preview would send everything typed to that server.
        if fallback.preview != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .fallback, in: container,
                debugDescription: "fallback cannot have a preview"
            )
        }
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
    /// argument (e.g. just "pr") and no workflow takes that keyword alone.
    /// Enter does nothing then, and the hint shows the workflow's help instead.
    func workflowAwaitingArgument(_ input: String) -> Workflow? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard workflow(for: input, withArgument: false) == nil else { return nil }
        return workflow(for: input, withArgument: true)
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
            loadError = nil
        } catch {
            loadError = Self.describe(error)
            NSLog("Launcher: ignoring %@: %@", fileURL.path, loadError ?? "")
        }
    }

    private static func describe(_ error: Error) -> String {
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

struct Command {
    let url: URL
    let label: String
    /// The workflow's preview URL, filled in with the same argument.
    var preview: URL?
    /// No keyword matched; this is the fallback search. Installed apps whose
    /// name matches the input take precedence over it.
    var isFallback = false
}

enum CommandParser {
    /// RFC 3986 unreserved characters; everything else gets percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Parses `<keyword> [argument]`, falling back to the fallback workflow.
    static func parse(_ raw: String, using set: WorkflowSet) -> Command? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let keyword = String(parts[0])
        if parts.count == 2, let workflow = set.workflow(for: keyword, withArgument: true) {
            let argument = workflow.prepare(parts[1].trimmingCharacters(in: .whitespaces))
            if !argument.isEmpty, let url = expand(workflow.url, with: argument) {
                return Command(
                    url: url, label: "\(workflow.title) \(argument)",
                    preview: workflow.preview.flatMap { expand($0, with: argument) }
                )
            }
        } else if parts.count == 1, let workflow = set.workflow(for: keyword, withArgument: false),
                  let url = URL(string: workflow.url) {
            return Command(url: url, label: workflow.title, preview: workflow.preview.flatMap { URL(string: $0) })
        }

        guard let url = expand(set.fallback.url, with: set.fallback.prepare(input)) else { return nil }
        return Command(url: url, label: set.fallback.title, isFallback: true)
    }

    private static func expand(_ template: String, with argument: String) -> URL? {
        guard let encoded = argument.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }
}
