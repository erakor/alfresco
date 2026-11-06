// AppIndex.swift
//
// The installed applications the launcher can open: AppIndex scans the
// usual Applications folders and matches launcher input against app names.

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
    /// Called on the main actor after a scan replaced `apps`.
    var onUpdate: (() -> Void)?
    private var lastScan: Date?
    private var scanning = false

    init() {
        refreshIfStale()
    }

    func refreshIfStale() {
        guard Config.appSearch, !scanning else { return }
        if let lastScan, Date().timeIntervalSince(lastScan) < Config.appRescanInterval { return }
        scanning = true
        let folders = Config.appFolders
        Task {
            let found = await Task.detached(priority: .utility) { AppIndex.scan(folders) }.value
            self.apps = found
            self.lastScan = Date()
            self.scanning = false
            self.onUpdate?()
        }
    }

    /// The apps whose name matches the whole input, best first, at most
    /// `limit` (see `ranked(_:for:limit:openCounts:picks:)`), with an
    /// "apps.match" signpost.
    func matches(
        for raw: String, limit: Int, openCounts: [String: Int] = [:], picks: [String: Double] = [:]
    ) -> [AppEntry] {
        guard Config.appSearch, limit > 0 else { return [] }
        let input = Self.fold(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !input.isEmpty else { return [] }
        #if SELFTEST
        Self.matchCallsForSelfTest += 1
        #endif

        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval(
            "apps.match",
            "apps=\(self.apps.count, privacy: .public) limit=\(limit, privacy: .public) inputLength=\(input.count, privacy: .public)"
        )
        let best = Self.ranked(apps, for: input, limit: limit, openCounts: openCounts, picks: picks)
        signposter.endInterval("apps.match", signpost, "matches=\(best.count, privacy: .public)")
        return best
    }

    /// `apps` whose name matches `input` (already folded and trimmed), best
    /// first, at most `limit`. Each match has a tier: the exact name, a name
    /// starting with the input, a word of the name starting with the input
    /// ("code" for "Visual Studio Code"), then the initials ("vsc").
    /// `openCounts` (bundle ID → times opened) lifts an app by up to
    /// `maxUsageBoost` tiers, one tier per `opensPerTier`-ish opens
    /// (logarithmic), so a much-used app can beat a closer-matching one.
    /// `picks` (bundle ID → weight, from TypedAppPicks: the apps opened for
    /// exactly this input) come before every tier but the exact name, the
    /// heaviest first. An exact name always comes first. Ties go to the
    /// shorter name, then alphabetical order.
    nonisolated static func ranked(
        _ apps: [AppEntry], for input: String, limit: Int,
        openCounts: [String: Int] = [:], picks: [String: Double] = [:]
    ) -> [AppEntry] {
        guard limit > 0, !input.isEmpty else { return [] }
        struct Ranked {
            /// 0: exact name, 1: picked for this input, 2: the rest.
            let group: Int
            let pickWeight: Double
            let score: Double
            let app: AppEntry
        }
        let ranked = apps.compactMap { app -> Ranked? in
            guard let rank = app.searchNames.compactMap({ Self.rank(input, in: $0) }).min() else { return nil }
            let opens = app.bundleID.flatMap { openCounts[$0] } ?? 0
            let weight = app.bundleID.flatMap { picks[$0] } ?? 0
            let group = rank == 0 ? 0 : weight > 0 ? 1 : 2
            return Ranked(group: group, pickWeight: weight, score: Self.score(rank: rank, opens: opens), app: app)
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.group != rhs.group { return lhs.group < rhs.group }
                if lhs.pickWeight != rhs.pickWeight { return lhs.pickWeight > rhs.pickWeight }
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.app.name.count != rhs.app.name.count { return lhs.app.name.count < rhs.app.name.count }
                return lhs.app.name < rhs.app.name
            }
            .prefix(limit)
            .map(\.app)
    }

    /// The best of `matches(for:limit:openCounts:picks:)`, or nil.
    func bestMatch(for raw: String, openCounts: [String: Int] = [:], picks: [String: Double] = [:]) -> AppEntry? {
        matches(for: raw, limit: 1, openCounts: openCounts, picks: picks).first
    }

    #if SELFTEST
    /// How many times `matches` ranked the apps, for the perf suite.
    static var matchCallsForSelfTest = 0
    #endif

    /// Opens worth one tier: about 31 opens lift an app one tier, about
    /// 1000 two (log2(1 + opens) / 5).
    private nonisolated static let opensPerTier = 5.0
    private nonisolated static let maxUsageBoost = 2.0

    /// Lower is better.
    private nonisolated static func score(rank: Int, opens: Int) -> Double {
        // An exact name stays first whatever the counts.
        if rank == 0 { return -maxUsageBoost - 1 }
        let boost = min(maxUsageBoost, log2(1 + Double(opens)) / opensPerTier)
        return Double(rank) - boost
    }

    private nonisolated static func rank(_ input: String, in name: String) -> Int? {
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
