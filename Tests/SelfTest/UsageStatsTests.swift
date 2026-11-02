// UsageStatsTests.swift
//
// usage.json: files from another version are set aside rather than
// overwritten, and the day cutoffs count calendar days, so daylight saving
// changes don't move them and exactly Config.usageRetentionDays days are kept.

import Foundation

@MainActor
private final class UsageClock {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

@MainActor
enum UsageStatsTests {
    private static var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func makeStats(_ clock: UsageClock, file: URL? = nil) -> UsageStats {
        UsageStats(fileURL: file ?? SelfTest.scratchFile("usage"), now: { clock.date }, calendar: paris)
    }

    static func run() {
        guard Config.usageTracking else {
            check("usage: Config.usageTracking is off, nothing to test", true)
            return
        }
        fileVersions()
        daylightSaving()
        retention()
    }

    private static func fileVersions() {
        let clock = UsageClock(date("2026-01-01T12:00:00Z"))

        let current = SelfTest.scratchFile("usage-v1")
        try? Data(#"{"version":1,"days":{"2026-01-01":{"counts":{"launcher.opened":3}}}}"#.utf8).write(to: current)
        let loaded = makeStats(clock, file: current)
        check("usage: a version 1 file loads", loaded.dayKeys == ["2026-01-01"], "days \(loaded.dayKeys)")

        let newer = SelfTest.scratchFile("usage-v2")
        let newerJSON = Data(#"{"version":2,"days":{},"somethingNew":true}"#.utf8)
        try? newerJSON.write(to: newer)
        let backup = newer.deletingPathExtension().appendingPathExtension("unreadable.json")
        let stats = makeStats(clock, file: newer)
        check("usage: a version 2 file is not loaded", stats.dayKeys.isEmpty, "days \(stats.dayKeys)")
        check("usage: a version 2 file is set aside as .unreadable.json",
              (try? Data(contentsOf: backup)) == newerJSON, "at \(backup.path)")
        stats.record(.launcherOpened)
        stats.saveNow()
        check("usage: saving afterwards keeps the version 2 file",
              (try? Data(contentsOf: backup)) == newerJSON)
        check("usage: and writes a new version 1 file",
              (try? String(contentsOf: newer, encoding: .utf8))?.contains(#""version" : 1"#) == true)

        // The newer build runs again and writes version 2 again: the next
        // launch of this one keeps both of its files.
        let newerAgain = Data(#"{"version":2,"days":{},"run":2}"#.utf8)
        try? newerAgain.write(to: newer)
        let secondBackup = newer.deletingPathExtension().appendingPathExtension("unreadable-2.json")
        let again = makeStats(clock, file: newer)
        check("usage: a second version 2 file is not loaded", again.dayKeys.isEmpty, "days \(again.dayKeys)")
        check("usage: the first set-aside file is kept", (try? Data(contentsOf: backup)) == newerJSON)
        check("usage: the second goes to .unreadable-2.json",
              (try? Data(contentsOf: secondBackup)) == newerAgain, "at \(secondBackup.path)")
    }

    private static func daylightSaving() {
        // Clocks go forward on 29 March 2026 in Paris: a 23 hour day.
        // 00:30 on 30 March (CEST) is only 23.5 hours after midnight on the 29th.
        let clock = UsageClock(date("2026-03-29T22:30:00Z"))
        let stats = makeStats(clock)
        check("usage: last 2 days after spring forward start on 29 March",
              stats.firstDayKeyForSelfTest(keeping: 2) == "2026-03-29", "got \(stats.firstDayKeyForSelfTest(keeping: 2))")
        check("usage: last 30 days after spring forward start on 1 March",
              stats.firstDayKeyForSelfTest(keeping: 30) == "2026-03-01", "got \(stats.firstDayKeyForSelfTest(keeping: 30))")

        // Clocks go back on 25 October 2026: a 25 hour day. 23:30 on the 25th
        // (CET) is 24.5 hours after midnight.
        clock.date = date("2026-10-25T22:30:00Z")
        check("usage: last 2 days after fall back start on 24 October",
              stats.firstDayKeyForSelfTest(keeping: 2) == "2026-10-24", "got \(stats.firstDayKeyForSelfTest(keeping: 2))")
        check("usage: last 1 day is today", stats.firstDayKeyForSelfTest(keeping: 1) == "2026-10-25",
              "got \(stats.firstDayKeyForSelfTest(keeping: 1))")
    }

    private static func retention() {
        // One event a day at 23:30 for longer than the retention window,
        // across the spring forward change.
        let clock = UsageClock(date("2026-01-01T22:30:00Z"))
        let stats = makeStats(clock)
        let days = Config.usageRetentionDays + 30
        for _ in 0..<days {
            stats.record(.launcherOpened)
            clock.date = paris.date(byAdding: .day, value: 1, to: clock.date)!
        }
        check("usage: exactly \(Config.usageRetentionDays) daily buckets are kept",
              stats.dayKeys.count == Config.usageRetentionDays, "kept \(stats.dayKeys.count)")
        let last = paris.dateComponents([.year, .month, .day], from: clock.date.addingTimeInterval(-24 * 3600))
        let lastKey = String(format: "%04d-%02d-%02d", last.year ?? 0, last.month ?? 0, last.day ?? 0)
        check("usage: the newest bucket is the last day recorded", stats.dayKeys.last == lastKey,
              "got \(stats.dayKeys.last ?? "nil"), expected \(lastKey)")
        check("usage: the oldest bucket is \(Config.usageRetentionDays - 1) days before it",
              stats.dayKeys.first == stats.firstDayKeyForSelfTest(keeping: Config.usageRetentionDays + 1),
              "got \(stats.dayKeys.first ?? "nil")")
    }
}
