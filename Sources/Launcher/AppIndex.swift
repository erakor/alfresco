// AppIndex.swift
//
// The installed applications the launcher can open: AppIndex scans the
// usual Applications folders and matches launcher input against app names,
// and against the System Settings panes this Mac has (SettingsPanes).

import Cocoa

/// One .app bundle found on disk.
struct AppEntry: Sendable {
    let url: URL
    /// What the launcher shows: Finder's (localized) name, e.g. "Calculatrice".
    let name: String
    /// Folded (lowercased, accents removed) names to match against: the
    /// localized name and the file name, which differ for system apps in
    /// other languages ("Calculatrice" / "Calculator").
    let searchNames: [String]
    /// For ranking by how often it is opened (UsageStats); nil for the rare
    /// bundle without one.
    let bundleID: String?
}

/// Keeps the list of installed apps and finds the best one for some input.
/// The folders are scanned off the main thread, at launch and again when the
/// launcher opens if the last scan is older than `Config.appRescanInterval`.
@MainActor
final class AppIndex {
    private(set) var apps: [AppEntry] = []
    /// The System Settings panes this Mac has (Config.settingsPaneSearch),
    /// read once with the first scan: they only change with macOS.
    private(set) var panes: [SettingsPane] = []
    /// Called on the main actor after a scan replaced `apps`.
    var onUpdate: (() -> Void)?
    private var lastScan: Date?
    private var scanning = false

    init() {
        refreshIfStale()
    }

    func refreshIfStale() {
        guard Config.appSearch || Config.settingsPaneSearch, !scanning else { return }
        if let lastScan, Date().timeIntervalSince(lastScan) < Config.appRescanInterval { return }
        scanning = true
        let folders = Config.appSearch ? Config.appFolders : []
        let readPanes = Config.settingsPaneSearch && lastScan == nil
        Task {
            let (found, panes) = await Task.detached(priority: .utility) {
                (AppIndex.scan(folders), readPanes ? SettingsPanes.installed() : nil)
            }.value
            self.apps = found
            if let panes { self.panes = panes }
            self.lastScan = Date()
            self.scanning = false
            self.onUpdate?()
        }
    }

    /// The apps and System Settings panes whose name matches the whole
    /// input, best first, at most `limit`: `.app` and `.settingsPane` rows.
    /// Each match has a tier: the exact name, a name starting with the
    /// input, a word of the name starting with the input ("code" for "Visual
    /// Studio Code"), then the initials ("vsc"). `openCounts` (bundle ID →
    /// times opened) lifts an app by up to `maxUsageBoost` tiers, one tier
    /// per `opensPerTier`-ish opens (logarithmic), so a much-used app can
    /// beat a closer-matching one; an exact name always comes first. Panes
    /// get no lift, and an app comes before a pane of the same score, so
    /// `bluetooth` gives the Bluetooth pane (an exact name) before Bluetooth
    /// File Exchange, but `s` keeps apps first. Ties go to the shorter name,
    /// then alphabetical order.
    func results(for raw: String, limit: Int, openCounts: [String: Int] = [:]) -> [LauncherItem] {
        guard limit > 0, !apps.isEmpty || !panes.isEmpty else { return [] }
        let input = Self.fold(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !input.isEmpty else { return [] }
        #if SELFTEST
        Self.matchCallsForSelfTest += 1
        #endif

        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval(
            "apps.match",
            "apps=\(self.apps.count, privacy: .public) panes=\(self.panes.count, privacy: .public) limit=\(limit, privacy: .public) inputLength=\(input.count, privacy: .public)"
        )
        let (best, matched) = Self.rank(input, apps: apps, panes: panes, limit: limit, openCounts: openCounts)
        signposter.endInterval("apps.match", signpost, "matches=\(matched, privacy: .public)")
        return best
    }

    /// The best of `results(for:limit:openCounts:)`, or nil.
    func bestResult(for raw: String, openCounts: [String: Int] = [:]) -> LauncherItem? {
        results(for: raw, limit: 1, openCounts: openCounts).first
    }

    /// `results`' ranking for folded `input`, and how many matched in all.
    nonisolated static func rank(
        _ input: String, apps: [AppEntry], panes: [SettingsPane], limit: Int, openCounts: [String: Int]
    ) -> (best: [LauncherItem], matched: Int) {
        typealias Ranked = (score: Double, isPane: Bool, length: Int, name: String, item: LauncherItem)
        let rankedApps = apps.compactMap { app -> Ranked? in
            guard let rank = app.searchNames.compactMap({ Self.rank(input, in: $0) }).min() else { return nil }
            let opens = app.bundleID.flatMap { openCounts[$0] } ?? 0
            return (Self.score(rank: rank, opens: opens), false, app.name.count, app.name, LauncherItem.app(app))
        }
        let rankedPanes = panes.compactMap { pane -> Ranked? in
            guard let rank = pane.searchNames.compactMap({ Self.rank(input, in: $0) }).min() else { return nil }
            let title = pane.title
            return (Self.score(rank: rank, opens: 0), true, title.count, title, LauncherItem.settingsPane(pane))
        }
        let ranked = rankedApps + rankedPanes
        let best = ranked
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.isPane != rhs.isPane { return !lhs.isPane }
                return (lhs.length, lhs.name) < (rhs.length, rhs.name)
            }
            .prefix(limit)
            .map(\.item)
        return (best, ranked.count)
    }

    #if SELFTEST
    /// How many times `results` ranked the apps, for the perf suite.
    static var matchCallsForSelfTest = 0
    #endif

    /// Opens worth one tier: about 31 opens lift an app one tier, about
    /// 1000 two (log2(1 + opens) / 5).
    nonisolated private static let opensPerTier = 5.0
    nonisolated private static let maxUsageBoost = 2.0

    /// Lower is better.
    nonisolated private static func score(rank: Int, opens: Int) -> Double {
        // An exact name stays first whatever the counts.
        if rank == 0 { return -maxUsageBoost - 1 }
        let boost = min(maxUsageBoost, log2(1 + Double(opens)) / opensPerTier)
        return Double(rank) - boost
    }

    nonisolated private static func rank(_ input: String, in name: String) -> Int? {
        if name == input { return 0 }
        if name.hasPrefix(input) { return 1 }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        // Several typed words must start the name's words in order, e.g.
        // "studio code"; one typed word can start any word.
        let typed = input.split(whereSeparator: \.isWhitespace)
        if typed.count == 1, words.dropFirst().contains(where: { $0.hasPrefix(typed[0]) }) { return 2 }
        if typed.count > 1, words.count >= typed.count {
            for start in 0...(words.count - typed.count)
            where zip(words[start...], typed).allSatisfy({ $0.hasPrefix($1) }) {
                return 2
            }
        }
        if words.count > 1, input.count > 1, input == String(words.compactMap(\.first)) { return 3 }
        return nil
    }

    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Lists the .app bundles directly in each folder and one level down
    /// (e.g. /Applications/Utilities), without looking inside bundles.
    nonisolated static func scan(_ folders: [URL]) -> [AppEntry] {
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval("apps.scan", id: signposter.makeSignpostID())
        let fileManager = FileManager.default
        var seen = Set<String>()
        var entries: [AppEntry] = []

        func add(_ url: URL) {
            let path = url.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else { return }
            let fileName = url.deletingPathExtension().lastPathComponent
            var display = fileManager.displayName(atPath: url.path)
            if display.lowercased().hasSuffix(".app") { display = String(display.dropLast(4)) }
            let names = Set([fold(display), fold(fileName)])
            let bundleID = Bundle(url: url)?.bundleIdentifier
            entries.append(AppEntry(url: url, name: display, searchNames: Array(names), bundleID: bundleID))
        }

        func contents(_ folder: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
        }

        for folder in folders {
            if folder.pathExtension == "app" {
                if fileManager.fileExists(atPath: folder.path) { add(folder) }
                continue
            }
            for item in contents(folder) {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    for inner in contents(item) where inner.pathExtension == "app" {
                        add(inner)
                    }
                }
            }
        }
        signposter.endInterval("apps.scan", signpost, "apps=\(entries.count, privacy: .public)")
        return entries
    }

    /// Opens (or brings forward) the app.
    static func open(_ app: AppEntry) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
            if let error {
                NSLog("Launcher: could not open %@: %@", app.url.path, error.localizedDescription)
            }
        }
    }
}
