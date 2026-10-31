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
/// the keyword alone. `description` is optional help text.
struct Workflow: Decodable, Sendable {
    let keywords: [String]
    let title: String
    let url: String
    /// Shown while the keyword is typed without its argument, and in the
    /// menu bar's Workflows submenu. Written as "description" in JSON.
    let help: String?
    let transforms: [ArgumentTransform]

    var takesArgument: Bool { url.contains("{query}") }

    private enum CodingKeys: String, CodingKey {
        case keywords, title, url, transforms
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

        if keywords.contains(where: { $0.isEmpty || $0.contains(where: \.isWhitespace) }) {
            throw DecodingError.dataCorruptedError(
                forKey: .keywords, in: container,
                debugDescription: "keywords must be single words"
            )
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
    }

    // swiftlint:disable:next force_try
    static let builtIn = try! JSONDecoder().decode(WorkflowSet.self, from: Data(Config.defaultWorkflowsJSON.utf8))

    func workflow(for keyword: String) -> Workflow? {
        let keyword = keyword.lowercased()
        return workflows.first { $0.keywords.contains(keyword) }
    }

    /// The workflow whose keyword is the whole input, when it still needs an
    /// argument (e.g. just "pr"). Enter does nothing then, and the hint shows
    /// the workflow's help instead.
    func workflowAwaitingArgument(_ input: String) -> Workflow? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workflow = workflow(for: input), workflow.takesArgument else { return nil }
        return workflow
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
        if let workflow = set.workflow(for: String(parts[0])) {
            if workflow.takesArgument, parts.count == 2 {
                let argument = workflow.prepare(parts[1].trimmingCharacters(in: .whitespaces))
                if !argument.isEmpty, let url = expand(workflow.url, with: argument) {
                    return Command(url: url, label: "\(workflow.title) \(argument)")
                }
            } else if !workflow.takesArgument, parts.count == 1, let url = URL(string: workflow.url) {
                return Command(url: url, label: workflow.title)
            }
        }

        guard let url = expand(set.fallback.url, with: set.fallback.prepare(input)) else { return nil }
        return Command(url: url, label: set.fallback.title)
    }

    private static func expand(_ template: String, with argument: String) -> URL? {
        guard let encoded = argument.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }
}
