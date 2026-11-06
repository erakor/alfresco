// StatsTests.swift
//
// `/stats`: the report adds up the last days (both forms of a keyword on
// one line, apps by name, clips restored, focus sessions on the day they
// ended), names the commands never run over every kept day, and the real
// launcher shows it while the input runs alfresco://stats. Assumes the
// shipped prefix, "/".

import Foundation

@MainActor
enum StatsTests {
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        SelfTest.check("stats: \(name)", condition, detail())
    }

    private static let json = #"""
    {"workflows": [
      {"keywords": ["pr"], "title": "PR", "url": "https://example.com/pr/{query}"},
      {"keywords": ["jira"], "title": "Jira", "url": "https://example.com/jira/{query}"},
      {"keywords": ["weather"], "title": "Weather here", "url": "https://example.com/w"},
      {"keywords": ["weather"], "title": "Weather in", "url": "https://example.com/w/{query}"},
      {"keywords": ["cf"], "title": "Contentful", "url": "https://example.com/cf/{query}"},
      {"keywords": ["stats"], "title": "Usage", "url": "alfresco://stats"},
      {"keywords": ["statsx"], "title": "Not the report", "url": "alfresco://stats/other"},
      {"keywords": ["zz"], "title": "Sleep", "url": "alfresco://system/sleep"}
    ]}
    """#

    private static var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    static func run() {
        guard Config.usageTracking else {
            check("Config.usageTracking is off, nothing to test", true)
            return
        }
        guard Config.commandPrefix == "/" else {
            check("the shipped prefix is /", false, "got \(Config.commandPrefix ?? "nil")")
            return
        }
        guard let set = try? JSONDecoder().decode(WorkflowSet.self, from: Data(json.utf8)) else {
            check("the test workflows decode", false)
            return
        }
        report(set)
        empty(set)
        text()
        pomodoro()
        launcher()
    }

    private static func report(_ set: WorkflowSet) {
        // Friday 6 November 2026, 12:00 in Paris.
        let clock = TestClock(ISO8601DateFormatter().date(from: "2026-11-06T11:00:00Z")!)
        let stats = UsageStats.makeForSelfTest(
            fileURL: SelfTest.scratchFile("usage-stats"), now: { clock.date }, calendar: paris
        )
        func daysAgo(_ days: Int) -> Date { clock.date.addingTimeInterval(-Double(days) * 86_400) }

        // 10 days ago: before the week, still kept.
        let today = clock.date
        clock.date = daysAgo(10)
        stats.recordLaunch(.workflow(keyword: "cf", withArgument: true), input: "/cf x", keywords: [])
        clock.date = today

        for _ in 0..<2 { stats.recordLaunch(.workflow(keyword: "pr", withArgument: false), input: "/pr", keywords: []) }
        for _ in 0..<3 { stats.recordLaunch(.workflow(keyword: "pr", withArgument: true), input: "/pr 1", keywords: []) }
        stats.recordLaunch(.workflow(keyword: "jira", withArgument: true), input: "/jira a-1", keywords: [])
        for _ in 0..<4 { stats.recordLaunch(.workflow(keyword: "stats", withArgument: false), input: "/stats", keywords: []) }
        stats.recordAppOpened(bundleID: "com.apple.Safari")
        stats.recordAppOpened(bundleID: "com.apple.Safari")
        stats.recordAppOpened(bundleID: "com.example.Notes")
        stats.recordAppOpened(bundleID: nil)
        for _ in 0..<3 { stats.recordClipboardRestore(bundleID: "com.apple.Safari") }
        stats.record(.pomodoroFocusCompleted, on: daysAgo(2))
        stats.record(.pomodoroFocusCompleted, on: daysAgo(9))
        stats.record(.pomodoroFocusCompleted, on: daysAgo(Config.usageRetentionDays + 10))
        stats.record(.pomodoroFocusCompleted, on: clock.date.addingTimeInterval(86_400))

        check("a day older than the kept ones records nothing",
              stats.dayKeys == ["2026-10-27", "2026-10-28", "2026-11-04", "2026-11-06"], "\(stats.dayKeys)")
        check("a day after today counts as today",
              stats.merged(days: 1).counts[UsageCounter.pomodoroFocusCompleted.rawValue] == 1)

        let names = ["com.apple.Safari": "Safari", "com.example.Notes": "Notes"]
        let report = UsageReport(
            recent: stats.merged(days: 7), kept: stats.totals(), days: 7,
            countingSince: stats.countingSince(withinLast: 7),
            unusedSince: stats.countingSince(withinLast: Config.usageRetentionDays),
            workflows: set, appName: { names[$0] ?? $0 }
        )
        let commands = report.topCommands.map { "\($0.name) \($0.count)" }
        check("both forms of a keyword make one line, most run first",
              commands == ["/pr 5", "/stats 4", "/jira 1"], "\(commands)")
        check("a line keeps the keyword as stored, for its icon", report.topCommands.first?.key == "pr")
        check("commands run counts every run of the week", report.commandsRun == 10, "\(report.commandsRun)")
        let apps = report.topApps.map { "\($0.name) \($0.count)" }
        check("apps by name, an app without a bundle ID left out of the list",
              apps == ["Safari 2", "Notes 1"], "\(apps)")
        check("apps opened counts them all", report.appsOpened == 4, "\(report.appsOpened)")
        check("clips restored", report.clipsRestored == 3, "\(report.clipsRestored)")
        check("focus sessions of the week only (2 days ago, and the one dated tomorrow)",
              report.focusSessions == 2, "\(report.focusSessions)")
        check("never run: over every kept day, in file order, the report itself left out",
              report.unusedCommands == ["/weather", "/statsx", "/zz"], "\(report.unusedCommands)")
        check("the week is covered: no 'since'", report.countingSince == nil)
        check("counting started 10 days ago, so 'never run' reaches back to then",
              report.unusedSince == paris.startOfDay(for: daysAgo(10)), "\(String(describing: report.unusedSince))")
        check("not empty", !report.isEmpty)
    }

    private static func empty(_ set: WorkflowSet) {
        let clock = TestClock(ISO8601DateFormatter().date(from: "2026-11-06T11:00:00Z")!)
        let stats = UsageStats.makeForSelfTest(
            fileURL: SelfTest.scratchFile("usage-stats-empty"), now: { clock.date }, calendar: paris
        )
        let report = UsageReport(
            recent: stats.merged(days: 7), kept: stats.totals(), days: 7,
            countingSince: stats.countingSince(withinLast: 7),
            unusedSince: stats.countingSince(withinLast: Config.usageRetentionDays),
            workflows: set, appName: { $0 }
        )
        check("nothing recorded: empty", report.isEmpty && report.topCommands.isEmpty && report.topApps.isEmpty)
        check("nothing recorded: counting starts today", report.countingSince == paris.startOfDay(for: clock.date))
        check("nothing recorded: every command is unused",
              report.unusedCommands == ["/pr", "/jira", "/weather", "/cf", "/statsx", "/zz"], "\(report.unusedCommands)")
    }

    private static func text() {
        check("title", UsageReport.title(days: 7, since: nil) == "Last 7 days")
        check("title since", UsageReport.title(days: 7, since: "3 Nov") == "Since 3 Nov")
        let two = UsageReport.unusedLine(["/cf", "/zz"], since: nil, retentionDays: 90)
        check("unused line", two == "2 never run in 90 days: /cf, /zz", two)
        let one = UsageReport.unusedLine(["/cf"], since: "3 Nov", retentionDays: 90)
        check("unused line since", one == "Never run since 3 Nov: /cf", one)
        let none = UsageReport.unusedLine([], since: nil, retentionDays: 90)
        check("unused line, none", none == "Every command ran in 90 days", none)
    }

    /// A focus session that runs its full length counts in the usage stats;
    /// a skipped one doesn't.
    private static func pomodoro() {
        let key = UsageCounter.pomodoroFocusCompleted.rawValue
        func count() -> Int { UsageStats.shared.merged(days: 1).counts[key] ?? 0 }
        let clock = TestClock(Date())
        let timer = PomodoroTimer(
            fileURL: SelfTest.scratchFile("stats-pomodoro"), now: { clock.date },
            wakeNotifications: NotificationCenter()
        )
        let before = count()
        timer.startFocus()
        timer.skip()
        check("a skipped focus session isn't counted", count() == before, "\(count()) after \(before)")
        timer.stop()
        timer.startFocus()
        clock.advance(Config.pomodoroFocus + 1)
        timer.tickForSelfTest()
        check("a finished focus session is counted", count() == before + 1, "\(count()) after \(before)")
        timer.stop()
    }

    /// The real LauncherController shows the report for the input that runs
    /// alfresco://stats, with its own hint, and only then.
    private static func launcher() {
        let url = SelfTest.scratchFile("stats-workflows")
        do {
            try Data(json.utf8).write(to: url)
        } catch {
            check("the test workflows file is written", false, error.localizedDescription)
            return
        }
        let controller = LauncherController(
            store: WorkflowStore(fileURL: url, createsMissingFile: false), internalURLHandler: { _ in true }
        )
        controller.typeForSelfTest("/stats")
        check("/stats shows the report", controller.statsForSelfTest != nil)
        check("its hint says what Enter does", controller.hintForSelfTest == "↩ Last 30 days in detail",
              controller.hintForSelfTest)
        check("over Config.usageReportDays", controller.statsForSelfTest?.days == Config.usageReportDays)
        controller.typeForSelfTest("/stats ")
        check("a trailing space still shows it", controller.statsForSelfTest != nil)
        for other in ["/stat", "/statsx", "/zz", "stats", "/", ""] {
            controller.typeForSelfTest(other)
            check("\"\(other)\" doesn't show it", controller.statsForSelfTest == nil)
        }
    }
}
