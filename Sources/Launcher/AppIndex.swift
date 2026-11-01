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

    /// The app whose name best matches the whole input, or nil. In order:
    /// the exact name, a name starting with the input, a word of the name
    /// starting with the input ("code" for "Visual Studio Code"), then the
    /// initials ("vsc"). Ties go to the shorter name.
    func bestMatch(for raw: String) -> AppEntry? {
        guard Config.appSearch else { return nil }
        let input = Self.fold(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !input.isEmpty else { return nil }

        var best: (rank: Int, length: Int, app: AppEntry)?
        for app in apps {
            guard let rank = app.searchNames.compactMap({ Self.rank(input, in: $0) }).min() else { continue }
            let length = app.name.count
            if let current = best, (current.rank, current.length) <= (rank, length) { continue }
            best = (rank, length, app)
        }
        return best?.app
    }

    private static func rank(_ input: String, in name: String) -> Int? {
        if name == input { return 0 }
        if name.hasPrefix(input) { return 1 }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        // Several typed words must start the name's words in order, e.g.
        // "studio code"; one typed word can start any word.
        let typed = input.split(whereSeparator: \.isWhitespace)
        if typed.count == 1, words.dropFirst().contains(where: { $0.hasPrefix(typed[0]) }) { return 2 }
        if typed.count > 1, let start = words.firstIndex(where: { $0.hasPrefix(typed[0]) }) {
            let rest = words[(start + 1)...]
            if rest.count >= typed.count - 1,
               zip(rest, typed.dropFirst()).allSatisfy({ $0.hasPrefix($1) }) {
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
            entries.append(AppEntry(url: url, name: display, searchNames: Array(names)))
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
