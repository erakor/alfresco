// TypedAppPicksTests.swift
//
// Learning which app goes with what you type: AppIndex.ranked puts the app
// picked for exactly this input first (an exact name aside), TypedAppPicks
// lets a new habit take over after a pick or two but not after one stray
// pick, keys inputs like app names are matched, and its file follows the
// usage stats' rules (StoreFile: owner-only, a damaged file set aside, which
// UsageStatsTests checks in full; old and excess inputs dropped).

import Foundation

@MainActor
enum TypedAppPicksTests {
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        SelfTest.check("app picks: \(name)", condition, detail())
    }

    private static let safari = "com.apple.Safari"
    private static let slack = "com.tinyspeck.slackmacgap"
    private static let sketch = "com.bohemiancoding.sketch3"

    private static func app(_ name: String, _ bundleID: String?) -> AppEntry {
        AppEntry(
            url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name,
            searchNames: [AppIndex.fold(name)], bundleID: bundleID
        )
    }

    private static var paris: Calendar { SelfTest.paris }

    private static func makePicks(_ clock: TestClock, file: URL? = nil) -> TypedAppPicks {
        TypedAppPicks.makeForSelfTest(
            fileURL: file ?? SelfTest.scratchFile("typed-picks"), now: { clock.date }, calendar: paris
        )
    }

    static func run() {
        ranking()
        guard Config.learnTypedAppPicks else {
            check("Config.learnTypedAppPicks is off, nothing more to test", true)
            return
        }
        learning()
        keys()
        file()
        retention()
    }

    private static func names(_ apps: [AppEntry]) -> [String] { apps.map(\.name) }

    private static func ranking() {
        let apps = [app("Safari", safari), app("Slack", slack), app("Sketch", sketch), app("Notes", "n"),
                    app("Notes Pro", "np")]
        let plain = AppIndex.ranked(apps, for: "s", limit: 9)
        check("without picks, ties go to the shorter name", names(plain) == ["Slack", "Safari", "Sketch"],
              "\(names(plain))")

        let picked = AppIndex.ranked(apps, for: "s", limit: 9, picks: [safari: 1])
        check("the app picked for this input comes first", names(picked) == ["Safari", "Slack", "Sketch"],
              "\(names(picked))")

        let heavier = AppIndex.ranked(apps, for: "s", limit: 9, picks: [safari: 1, sketch: 3])
        check("several picks: the heaviest first, then the rest",
              names(heavier) == ["Sketch", "Safari", "Slack"], "\(names(heavier))")

        let opened = AppIndex.ranked(apps, for: "s", limit: 9, openCounts: [slack: 5000], picks: [safari: 0.5])
        check("a pick beats an app opened far more often", names(opened).first == "Safari", "\(names(opened))")

        let exact = AppIndex.ranked(apps, for: "notes", limit: 9, picks: ["np": 8])
        check("an exact name still comes first", names(exact) == ["Notes", "Notes Pro"], "\(names(exact))")

        let notMatching = AppIndex.ranked(apps, for: "sl", limit: 9, picks: [safari: 8])
        check("a picked app that doesn't match the input isn't added", names(notMatching) == ["Slack"],
              "\(names(notMatching))")

        let limited = AppIndex.ranked(apps, for: "s", limit: 1, picks: [sketch: 1])
        check("the pick is what the limit keeps (Enter's app)", names(limited) == ["Sketch"], "\(names(limited))")
    }

    private static func learning() {
        let clock = TestClock(SelfTest.date("2026-11-06T10:00:00Z"))
        let picks = makePicks(clock)
        check("nothing learned at first", picks.picks(for: "s").isEmpty && picks.isEmpty)

        picks.record(input: "s", bundleID: safari)
        check("a pick is remembered for that input", picks.picks(for: "s") == [safari: 1], "\(picks.picks(for: "s"))")
        check("but not for a longer or shorter one", picks.picks(for: "sa").isEmpty && picks.picks(for: "").isEmpty)

        picks.record(input: "s", bundleID: slack)
        let switched = picks.picks(for: "s")
        check("after one pick each, the latest leads",
              (switched[slack] ?? 0) > (switched[safari] ?? 0), "\(switched)")

        for _ in 0..<6 { picks.record(input: "sl", bundleID: slack) }
        picks.record(input: "sl", bundleID: sketch)
        let habit = picks.picks(for: "sl")
        check("one stray pick doesn't undo a habit", (habit[slack] ?? 0) > (habit[sketch] ?? 0), "\(habit)")
        for _ in 0..<2 { picks.record(input: "sl", bundleID: sketch) }
        let changed = picks.picks(for: "sl")
        check("a few picks do", (changed[sketch] ?? 0) > (changed[slack] ?? 0), "\(changed)")

        for _ in 0..<50 { picks.record(input: "x", bundleID: safari) }
        check("a weight stops growing at maxWeight",
              picks.picks(for: "x")[safari] == TypedAppPicks.maxWeight, "\(picks.picks(for: "x"))")
        for _ in 0..<10 { picks.record(input: "x", bundleID: slack) }
        check("an app not picked for long is dropped from the input", picks.picks(for: "x")[safari] == nil,
              "\(picks.picks(for: "x"))")

        picks.record(input: "q", bundleID: nil)
        check("an app without a bundle ID isn't kept", picks.picks(for: "q").isEmpty)

        picks.forgetAll()
        check("forgetting empties everything", picks.isEmpty && picks.picks(for: "sl").isEmpty)
    }

    private static func keys() {
        check("inputs are trimmed and folded like app names", TypedAppPicks.key(for: "  Écrit ") == "ecrit",
              TypedAppPicks.key(for: "  Écrit ") ?? "nil")
        check("blank input isn't a key", TypedAppPicks.key(for: "   ") == nil)
        let long = String(repeating: "a", count: TypedAppPicks.maxInputLength + 1)
        check("input over maxInputLength isn't a key", TypedAppPicks.key(for: long) == nil)

        let clock = TestClock()
        let picks = makePicks(clock)
        picks.record(input: " SAF ", bundleID: safari)
        check("a pick typed in capitals counts for the same input", picks.picks(for: "saf") == [safari: 1],
              "\(picks.picks(for: "saf"))")
        picks.record(input: long, bundleID: safari)
        check("a pick for too long an input isn't kept", picks.inputsForSelfTest == ["saf"], "\(picks.inputsForSelfTest)")
    }

    private static func file() {
        let clock = TestClock(SelfTest.date("2026-11-06T10:00:00Z"))
        let url = SelfTest.scratchFile("typed-picks-file")
        let first = makePicks(clock, file: url)
        first.record(input: "s", bundleID: safari)
        first.saveNow()
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        check("the file is owner-only", mode == 0o600, mode.map { String($0, radix: 8) } ?? "missing")
        first.forgetAll()
        check("forgetting empties the file right away", makePicks(clock, file: url).isEmpty)
        first.record(input: "s", bundleID: safari)
        first.saveNow()
        let reread = makePicks(clock, file: url)
        check("picks are read back from the file", reread.picks(for: "s") == [safari: 1], "\(reread.picks(for: "s"))")

        let damaged = SelfTest.scratchFile("typed-picks-damaged")
        let damagedJSON = Data("{not json".utf8)
        try? damagedJSON.write(to: damaged)
        let backup = damaged.deletingPathExtension().appendingPathExtension("unreadable.json")
        let fromDamaged = makePicks(clock, file: damaged)
        fromDamaged.record(input: "s", bundleID: safari)
        fromDamaged.saveNow()
        check("a damaged file is set aside as .unreadable.json", (try? Data(contentsOf: backup)) == damagedJSON,
              "at \(backup.path)")
        check("then a new file is written", makePicks(clock, file: damaged).picks(for: "s") == [safari: 1])
    }

    private static func retention() {
        let clock = TestClock(SelfTest.date("2026-01-01T10:00:00Z"))
        let url = SelfTest.scratchFile("typed-picks-retention")
        let picks = makePicks(clock, file: url)
        picks.record(input: "old", bundleID: safari)
        clock.date = paris.date(byAdding: .day, value: Config.typedAppPicksRetentionDays - 1, to: clock.date)!
        picks.record(input: "new", bundleID: slack)
        check("an input typed \(Config.typedAppPicksRetentionDays - 1) days ago is kept",
              picks.inputsForSelfTest == ["new", "old"], "\(picks.inputsForSelfTest)")
        check("it still ranks", picks.picks(for: "old") == [safari: 1], "\(picks.picks(for: "old"))")
        clock.date = paris.date(byAdding: .day, value: 1, to: clock.date)!
        check("one past the retention window no longer ranks, before anything prunes it",
              picks.picks(for: "old").isEmpty && picks.inputsForSelfTest == ["new", "old"], "\(picks.picks(for: "old"))")
        picks.record(input: "new", bundleID: slack)
        check("one past the retention window is dropped", picks.inputsForSelfTest == ["new"], "\(picks.inputsForSelfTest)")
        picks.saveNow()
        clock.date = paris.date(byAdding: .day, value: Config.typedAppPicksRetentionDays, to: clock.date)!
        check("old inputs are dropped when the file is read", makePicks(clock, file: url).inputsForSelfTest.isEmpty)

        let many = makePicks(clock)
        let limit = Config.typedAppPicksMaxInputs
        for index in 0..<(limit + 5) {
            many.record(input: "app\(index)", bundleID: safari)
        }
        check("at most \(limit) inputs are kept", many.inputsForSelfTest.count == limit, "\(many.inputsForSelfTest.count)")
        check("the one just typed is among them", !many.picks(for: "app\(limit + 4)").isEmpty)
    }
}
