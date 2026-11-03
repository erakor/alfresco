// WorkflowCheck.swift
//
// `Launcher --check [file ...]`: decodes workflows files with the app's own
// decoder, prints what is wrong with each and exits, without starting the
// app. Also compiled by .claude/skills/add-workflow/scripts/check.sh, so it
// uses only Foundation and Workflows.swift.

import Foundation

/// What is wrong with one workflows file, as the app would see it.
struct WorkflowCheck: Sendable {
    enum Severity: String, Sendable {
        /// The app can't use the file, or leaves part of it out.
        case error
        /// The file loads, but something in it can never run.
        case warning
    }

    struct Problem: Sendable, Equatable {
        let severity: Severity
        let message: String
    }

    /// The decoded file, nil when it doesn't decode (the app then keeps its
    /// last good version).
    let set: WorkflowSet?
    let problems: [Problem]

    /// No errors; warnings are allowed.
    var passed: Bool { !problems.contains { $0.severity == .error } }

    init(data: Data) {
        let set: WorkflowSet
        do {
            set = try JSONDecoder().decode(WorkflowSet.self, from: data)
        } catch {
            self.init(set: nil, problems: [Problem(severity: .error, message: WorkflowStore.describe(error))])
            return
        }
        self.init(set: set, problems: set.refused.map { Problem(severity: .error, message: "refused \($0)") }
            + WorkflowCheck.shadowedKeywords(in: set).map { Problem(severity: .warning, message: $0) })
    }

    init(fileURL: URL) {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            self.init(set: nil, problems: [Problem(severity: .error, message: "cannot read the file: \(error.localizedDescription)")])
            return
        }
        self.init(data: data)
    }

    private init(set: WorkflowSet?, problems: [Problem]) {
        self.set = set
        self.problems = problems
    }

    /// A keyword may be used once with {query} and once without; a second
    /// use of the same form never runs, since the first workflow wins.
    static func shadowedKeywords(in set: WorkflowSet) -> [String] {
        var firstUse: [String: Int] = [:]
        var messages: [String] = []
        for (index, workflow) in set.workflows.enumerated() {
            for keyword in workflow.keywords {
                let form = workflow.takesArgument ? "with an argument" : "alone"
                let key = "\(keyword)|\(workflow.takesArgument)"
                guard let first = firstUse[key] else {
                    firstUse[key] = index
                    continue
                }
                if first == index {
                    messages.append("keyword \"\(keyword)\" is listed twice in \"\(workflow.title)\"")
                } else {
                    messages.append("keyword \"\(keyword)\" \(form) is used by \"\(set.workflows[first].title)\" and \"\(workflow.title)\"; only the first runs")
                }
            }
        }
        return messages
    }

    /// The lines printed for the file, each starting with `name`, the last
    /// one the verdict.
    func report(name: String) -> [String] {
        var lines = problems.map { "\(name): \($0.severity.rawValue): \($0.message)" }
        let errors = problems.filter { $0.severity == .error }.count
        let warnings = problems.count - errors
        func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if passed {
            var details = [count(set?.workflows.count ?? 0, "workflow")]
            details.append(set?.fallback.map { "fallback \"\($0.title)\"" } ?? "no fallback")
            if warnings > 0 { details.append(count(warnings, "warning")) }
            lines.append("\(name): OK (\(details.joined(separator: ", ")))")
        } else {
            lines.append("\(name): FAILED (\(count(errors, "error"))\(warnings > 0 ? ", " + count(warnings, "warning") : ""))")
        }
        return lines
    }

    /// Checks each file, prints the reports and returns the exit status: 0
    /// when every file passed, else 1.
    static func run(_ files: [(name: String, url: URL)]) -> Int32 {
        var status: Int32 = 0
        for file in files {
            let check = WorkflowCheck(fileURL: file.url)
            for line in check.report(name: file.name) { print(line) }
            if !check.passed { status = 1 }
        }
        return status
    }
}
