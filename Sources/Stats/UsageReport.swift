// UsageReport.swift
//
// What `/stats` shows under the launcher input, worked out from the usage
// stats without AppKit so the self-test can check it: the last
// Config.usageReportDays days as four figures (commands run, apps opened,
// clips restored, focus sessions) and two top lists, then the commands of
// workflows.json that never ran over every kept day.

import Foundation

struct UsageReport: Equatable, Sendable {
    /// One line of a top list.
    struct Entry: Equatable, Sendable {
        /// What the line reads: `/pr`, or the app's name.
        var name: String
        /// What its icon is looked up by: the keyword as stored (`pr`), or
        /// the app's bundle ID.
        var key: String
        var count: Int
    }

    /// Lines in each top list.
    static let listLimit = 5

    /// The days summed up, today included.
    var days: Int
    /// The first of those days with counters, when counting started after
    /// the first of them; nil when the counters reach back over all of them.
    var countingSince: Date?
    /// Workflows run (both forms of a keyword), apps opened from the
    /// launcher, clips put back on the clipboard, and focus sessions that
    /// ran their full length.
    var commandsRun = 0
    var appsOpened = 0
    var clipsRestored = 0
    var focusSessions = 0
    /// The most run keywords, both forms added up, at most listLimit.
    var topCommands: [Entry] = []
    /// The most opened apps, at most listLimit.
    var topApps: [Entry] = []
    /// Keywords (typed, `/cf`) none of whose forms ran over every kept day,
    /// in workflows.json order. Workflows that open this report are left out.
    var unusedCommands: [String] = []
    /// When counting started, if later than Config.usageRetentionDays ago:
    /// "never run" only reaches back to then.
    var unusedSince: Date?

    /// Nothing at all in the days summed up.
    var isEmpty: Bool { commandsRun + appsOpened + clipsRestored + focusSessions == 0 }

    /// `recent` is the last `days` days added up, `kept` every kept day.
    /// `appName` turns a bundle ID into what the list shows; two IDs with the
    /// same name share a line.
    init(
        recent: UsageDay, kept: UsageTotals, days: Int, countingSince: Date?, unusedSince: Date?,
        workflows: WorkflowSet, appName: (String) -> String
    ) {
        self.days = days
        self.countingSince = countingSince
        self.unusedSince = unusedSince

        var byKeyword: [String: Int] = [:]
        for (key, count) in recent.keywords {
            byKeyword[Self.keyword(fromUsageKey: key), default: 0] += count
        }
        commandsRun = byKeyword.values.reduce(0, +)
        topCommands = Self.top(byKeyword.map { Entry(name: CommandInput.typed($0.key), key: $0.key, count: $0.value) })

        // Sorted, so the bundle ID a shared name keeps is always the same one.
        var byApp: [String: Entry] = [:]
        for (id, count) in recent.appsOpened.sorted(by: { $0.key < $1.key }) where id != "unknown" {
            let name = appName(id)
            byApp[name, default: Entry(name: name, key: id, count: 0)].count += count
        }
        appsOpened = recent.counts[UsageCounter.launcherOpenedApp.rawValue] ?? 0
        topApps = Self.top(Array(byApp.values))

        clipsRestored = recent.clipboardRestores.values.reduce(0, +)
        focusSessions = recent.counts[UsageCounter.pomodoroFocusCompleted.rawValue] ?? 0

        // Counted as UsageStats.recordLaunch keys them: under the first
        // keyword of the workflow that ran, " …" for the argument form.
        var seen = Set<String>()
        for workflow in workflows.workflows where !Self.opensReport(workflow) {
            guard let keyword = workflow.keywords.first, seen.insert(keyword).inserted else { continue }
            let runs = (kept.keywords[keyword] ?? 0) + (kept.keywords["\(keyword) …"] ?? 0)
            if runs == 0 { unusedCommands.append(CommandInput.typed(keyword)) }
        }
    }

    /// `pr` for both "pr" and "pr …" (the argument form) in usage.json.
    static func keyword(fromUsageKey key: String) -> String {
        key.hasSuffix(" …") ? String(key.dropLast(2)) : key
    }

    /// Whether a workflow opens this report (alfresco://stats): looking at
    /// the report is no reason to list it as unused.
    static func opensReport(_ workflow: Workflow) -> Bool {
        URL(string: workflow.url).map(StatsCommand.isSummary) == true
    }

    /// Most first, then by name; at most listLimit.
    private static func top(_ entries: [Entry]) -> [Entry] {
        let sorted = entries.filter { $0.count > 0 }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Array(sorted.prefix(listLimit))
    }

    // MARK: Text

    /// "Last 7 days", or "Since 3 Nov" when counting started after the
    /// first of them. `since` is that day as shown.
    static func title(days: Int, since: String?) -> String {
        if let since { return "Since \(since)" }
        return days == 1 ? "Today" : "Last \(days) days"
    }

    /// The line under the lists: which commands never ran, over
    /// `retentionDays` or since `since` (the day counting started, as shown).
    static func unusedLine(_ unused: [String], since: String?, retentionDays: Int) -> String {
        let period = since.map { "since \($0)" } ?? "in \(retentionDays) days"
        if unused.isEmpty { return "Every command ran \(period)" }
        let what = unused.count == 1 ? "Never run" : "\(unused.count) never run"
        return "\(what) \(period): " + unused.joined(separator: ", ")
    }
}

extension UsageReport {
    /// The report for `stats` as it is now, over `days` days.
    @MainActor
    static func make(from stats: UsageStats, workflows: WorkflowSet, days: Int = Config.usageReportDays) -> UsageReport {
        UsageReport(
            recent: stats.merged(days: days), kept: stats.totals(), days: days,
            countingSince: stats.countingSince(withinLast: days),
            unusedSince: stats.countingSince(withinLast: Config.usageRetentionDays),
            workflows: workflows, appName: { UsageStats.appName(for: $0) }
        )
    }
}
