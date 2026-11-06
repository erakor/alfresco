// TypedAppPicks.swift
//
// Which app you open for what you type: `s` → Safari, `sl` → Slack. The
// launcher puts that app first the next time exactly that is typed, above
// apps that only match better by name or are opened more often overall
// (UsageStats). Kept in ~/Library/Application Support/Launcher/typed-picks.json,
// on its own Config switch (Config.learnTypedAppPicks), since it holds what
// was typed: only input that opened an app, which always matches an installed
// app's name, folded (lowercased, accents removed), with the app's bundle ID
// and the day it was last typed. Nothing is sent anywhere.

import Foundation

/// The apps picked for one typed input.
struct TypedInputPicks: Codable, Sendable {
    /// Bundle ID → weight. A pick adds 1 to its app (at most
    /// `TypedAppPicks.maxWeight`) and halves every other one, so the app
    /// picked most lately leads after a pick or two, while a single stray
    /// pick doesn't undo a long habit.
    var apps: [String: Double]
    /// The local day it was last typed to open an app, "yyyy-MM-dd".
    var lastUsed: String
}

/// File format: { "version": 1, "inputs": { "s": { "apps": {...}, "lastUsed": "2026-11-06" } } }.
/// StoreFile reads only version 1.
private struct StoredTypedPicks: Codable {
    static let currentVersion = 1
    var version = Self.currentVersion
    var inputs: [String: TypedInputPicks] = [:]
}

@MainActor
final class TypedAppPicks {
    static let shared = TypedAppPicks()

    /// typed-picks.json: read when first used, saved 5 s after a change and on quit.
    private let file: StoreFile
    /// The current time and calendar. Only the self-test passes others.
    private let now: @MainActor () -> Date
    private let calendar: Calendar
    private var stored = StoredTypedPicks()

    /// Inputs longer than this are not kept. Input that opens an app matches
    /// its name, so this only stops something odd from being stored.
    nonisolated static let maxInputLength = 40
    /// The weight one app can reach for an input (see TypedInputPicks.apps).
    nonisolated static let maxWeight = 8.0
    /// A weight halved below this is dropped: about five picks of other apps.
    nonisolated static let minWeight = 0.25

    private convenience init() {
        self.init(fileURL: ClipboardStore.directory.appendingPathComponent("typed-picks.json"),
                  now: { Date() }, calendar: .autoupdatingCurrent)
    }

    /// Private, so `shared` is the only instance on the file. The self-test
    /// uses makeForSelfTest.
    private init(fileURL: URL, now: @escaping @MainActor () -> Date, calendar: Calendar) {
        file = StoreFile(url: fileURL, name: "learned app picks", kind: .typedAppPicks)
        self.now = now
        self.calendar = calendar
        guard Config.learnTypedAppPicks else { return }
        stored = file.load(StoredTypedPicks.self, currentVersion: StoredTypedPicks.currentVersion)
            ?? StoredTypedPicks()
        prune()
    }

    /// How an input is stored and looked up: normalized like the input app
    /// names are matched against (AppIndex.normalize), so `S `, `s` and `ś`
    /// are one input. nil for input that is empty or too long to keep.
    nonisolated static func key(for input: String) -> String? {
        let key = AppIndex.normalize(input)
        guard !key.isEmpty, key.count <= maxInputLength else { return nil }
        return key
    }

    /// Bundle ID → weight of the apps opened for exactly this input, for
    /// AppIndex.results. Empty when nothing was, or when learning is off.
    /// An input past the retention window counts as forgotten even before
    /// prune drops it (a long-running app prunes only when it records).
    func picks(for input: String) -> [String: Double] {
        guard Config.learnTypedAppPicks, let key = Self.key(for: input),
              let entry = stored.inputs[key], entry.lastUsed >= retentionCutoff()
        else { return [:] }
        return entry.apps
    }

    /// The launcher opened the app with `bundleID` while `input` was typed.
    func record(input: String, bundleID: String?) {
        guard Config.learnTypedAppPicks, let bundleID, let key = Self.key(for: input) else { return }
        let previous = stored.inputs[key]?.apps ?? [:]
        var apps = previous.mapValues { $0 / 2 }.filter { $0.value >= Self.minWeight }
        apps[bundleID] = min(Self.maxWeight, (previous[bundleID] ?? 0) + 1)
        stored.inputs[key] = TypedInputPicks(apps: apps, lastUsed: DayKey.of(now(), in: calendar))
        prune(keeping: key)
        scheduleSave()
    }

    /// Forgets everything learned and empties the file right away (the menu
    /// bar's "Forget Learned App Picks").
    func forgetAll() {
        guard !stored.inputs.isEmpty else { return }
        stored.inputs = [:]
        scheduleSave()
        file.saveNow()
    }

    var isEmpty: Bool { stored.inputs.isEmpty }

    /// Writes any pending change; called on quit.
    func saveNow() {
        file.saveNow()
    }

    /// Drops inputs not typed in the last Config.typedAppPicksRetentionDays
    /// calendar days (today included), then the least recently typed ones
    /// past Config.typedAppPicksMaxInputs, never `kept` (the one just typed).
    private func prune(keeping kept: String? = nil) {
        let cutoff = retentionCutoff()
        let before = stored.inputs.count
        stored.inputs = stored.inputs.filter { $0.value.lastUsed >= cutoff }
        let excess = stored.inputs.count - max(0, Config.typedAppPicksMaxInputs)
        if excess > 0 {
            let oldest = stored.inputs
                .filter { $0.key != kept }
                .sorted { ($0.value.lastUsed, $0.key) < ($1.value.lastUsed, $1.key) }
                .prefix(excess)
            for (key, _) in oldest { stored.inputs[key] = nil }
        }
        if stored.inputs.count != before { scheduleSave() }
    }

    /// The oldest day an input may have been last typed on and still count.
    private func retentionCutoff() -> String {
        DayKey.first(keeping: Config.typedAppPicksRetentionDays, upTo: now(), in: calendar)
    }

    private func scheduleSave() {
        file.scheduleSave { self.stored }
    }

    #if SELFTEST
    static func makeForSelfTest(fileURL: URL, now: @escaping @MainActor () -> Date, calendar: Calendar) -> TypedAppPicks {
        TypedAppPicks(fileURL: fileURL, now: now, calendar: calendar)
    }

    /// The stored inputs, sorted.
    var inputsForSelfTest: [String] { stored.inputs.keys.sorted() }
    #endif
}
