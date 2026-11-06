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
import os

/// The apps picked for one typed input.
struct TypedInputPicks: Codable, Sendable {
    /// Bundle ID → weight. A pick adds 1 to its app (at most
    /// `TypedAppPicks.maxWeight`) and halves every other one, so the app
    /// picked most lately leads after a pick or two, while a single stray
    /// pick doesn't undo a long habit.
    var apps: [String: Double] = [:]
    /// The local day it was last typed to open an app, "yyyy-MM-dd".
    var lastUsed: String
}

/// File format: { "version": 1, "inputs": { "s": { "apps": {...}, "lastUsed": "2026-11-06" } } }.
private struct StoredTypedPicks: Codable {
    static let currentVersion = 1
    var version = Self.currentVersion
    var inputs: [String: TypedInputPicks] = [:]

    init() {}

    /// Another version is refused: load() leaves a newer build's file where
    /// it is and doesn't save over it (see StoredTypedPicksVersion).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container,
                debugDescription: "typed-picks.json version \(version) is not supported (expected \(Self.currentVersion))")
        }
        inputs = try container.decode([String: TypedInputPicks].self, forKey: .inputs)
    }
}

/// Just the version, to tell a newer build's file from a damaged one.
private struct StoredTypedPicksVersion: Decodable {
    var version: Int
}

@MainActor
final class TypedAppPicks: NSObject {
    static let shared = TypedAppPicks()

    let fileURL: URL
    /// The current time and calendar. Only the self-test passes others.
    private let now: @MainActor () -> Date
    private let calendar: Calendar
    private var stored = StoredTypedPicks()
    private var saveTimer: Timer?
    /// False when the file is from a newer build, or is unreadable and
    /// couldn't be set aside: nothing is saved over it this run.
    private var canSave = true

    /// Inputs longer than this are not kept. Input that opens an app matches
    /// its name, so this only stops something odd from being stored.
    nonisolated static let maxInputLength = 40
    /// The weight one app can reach for an input (see TypedInputPicks.apps).
    nonisolated static let maxWeight = 8.0
    /// A weight halved below this is dropped: about five picks of other apps.
    nonisolated static let minWeight = 0.25

    private override convenience init() {
        self.init(fileURL: ClipboardStore.directory.appendingPathComponent("typed-picks.json"),
                  now: { Date() }, calendar: .autoupdatingCurrent)
    }

    /// Private, so `shared` is the only instance on the file. The self-test
    /// uses makeForSelfTest.
    private init(fileURL: URL, now: @escaping @MainActor () -> Date, calendar: Calendar) {
        self.fileURL = fileURL
        self.now = now
        self.calendar = calendar
        super.init()
        guard Config.learnTypedAppPicks else { return }
        load()
        prune()
    }

    /// How an input is stored and looked up: trimmed and folded like app
    /// names (AppIndex.fold), so `S `, `s` and `ś` are one input. nil for
    /// input that is empty or too long to keep.
    nonisolated static func key(for input: String) -> String? {
        let key = AppIndex.fold(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty, key.count <= maxInputLength else { return nil }
        return key
    }

    /// Bundle ID → weight of the apps opened for exactly this input, for
    /// AppIndex.matches. Empty when nothing was, or when learning is off.
    func picks(for input: String) -> [String: Double] {
        guard Config.learnTypedAppPicks, let key = Self.key(for: input) else { return [:] }
        return stored.inputs[key]?.apps ?? [:]
    }

    /// The launcher opened the app with `bundleID` while `input` was typed.
    func record(input: String, bundleID: String?) {
        guard Config.learnTypedAppPicks, let bundleID, let key = Self.key(for: input) else { return }
        var entry = stored.inputs[key] ?? TypedInputPicks(lastUsed: "")
        var apps: [String: Double] = [:]
        for (id, weight) in entry.apps where id != bundleID && weight / 2 >= Self.minWeight {
            apps[id] = weight / 2
        }
        apps[bundleID] = min(Self.maxWeight, (entry.apps[bundleID] ?? 0) + 1)
        entry.apps = apps
        entry.lastUsed = dayKey(for: now())
        stored.inputs[key] = entry
        prune(keeping: key)
        scheduleSave()
    }

    /// Forgets everything learned (the menu bar's "Forget Learned App Picks").
    func forgetAll() {
        guard !stored.inputs.isEmpty else { return }
        stored.inputs = [:]
        scheduleSave()
    }

    var isEmpty: Bool { stored.inputs.isEmpty }

    // MARK: Storage

    /// The local calendar day, e.g. "2026-11-01"; sorts like the dates.
    private func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Drops inputs not typed in the last Config.typedAppPicksRetentionDays
    /// calendar days (today included), then the least recently typed ones
    /// past Config.typedAppPicksMaxInputs, never `kept` (the one just typed).
    private func prune(keeping kept: String? = nil) {
        let today = calendar.startOfDay(for: now())
        let days = max(1, Config.typedAppPicksRetentionDays)
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let cutoff = dayKey(for: first)
        let before = stored.inputs.count
        stored.inputs = stored.inputs.filter { $0.value.lastUsed >= cutoff }
        let limit = max(0, Config.typedAppPicksMaxInputs)
        if stored.inputs.count > limit {
            let oldest = stored.inputs
                .filter { $0.key != kept }
                .sorted { ($0.value.lastUsed, $0.key) < ($1.value.lastUsed, $1.key) }
                .prefix(stored.inputs.count - limit)
            for (key, _) in oldest { stored.inputs[key] = nil }
        }
        if stored.inputs.count != before { scheduleSave() }
    }

    private func scheduleSave() {
        guard canSave, saveTimer == nil else { return }
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(saveTimerFired), userInfo: nil, repeats: false)
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    @objc private func saveTimerFired() {
        saveNow()
    }

    /// Writes any pending change; called on quit.
    func saveNow() {
        guard saveTimer != nil else { return }
        saveTimer?.invalidate()
        saveTimer = nil

        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval("apps.picks.save", "inputs=\(self.stored.inputs.count, privacy: .public)")
        defer { signposter.endInterval("apps.picks.save", signpost) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            // What was typed: owner-only access.
            try ClipImageFile.createPrivateDirectory(fileURL.deletingLastPathComponent())
            try encoder.encode(stored).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Launcher: could not save learned app picks: \(error)")
        }
    }

    private func load() {
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval("apps.picks.load")
        defer { signposter.endInterval("apps.picks.load", signpost, "inputs=\(self.stored.inputs.count, privacy: .public)") }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return  // Nothing learned yet.
        } catch {
            setAside(error)
            return
        }
        do {
            stored = try JSONDecoder().decode(StoredTypedPicks.self, from: data)
        } catch {
            if let version = try? JSONDecoder().decode(StoredTypedPicksVersion.self, from: data).version,
               version > StoredTypedPicks.currentVersion {
                canSave = false
                NSLog("Launcher: typed-picks.json is version \(version), from a newer build; app picks won't be saved this run")
            } else {
                setAside(error)
            }
        }
    }

    /// Moves an unreadable file out of the way rather than overwrite it. If
    /// it can't be moved, nothing is saved this run.
    private func setAside(_ error: Error) {
        if let backup = SetAsideFile.move(fileURL) {
            NSLog("Launcher: unreadable learned app picks moved to \(backup.path): \(error)")
        } else {
            canSave = false
            NSLog("Launcher: could not set aside unreadable learned app picks, so they won't be saved this run: \(error)")
        }
    }

    #if SELFTEST
    static func makeForSelfTest(fileURL: URL, now: @escaping @MainActor () -> Date, calendar: Calendar) -> TypedAppPicks {
        TypedAppPicks(fileURL: fileURL, now: now, calendar: calendar)
    }

    /// The stored inputs, sorted.
    var inputsForSelfTest: [String] { stored.inputs.keys.sorted() }
    var canSaveForSelfTest: Bool { canSave }
    #endif
}
