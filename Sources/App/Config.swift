// Config.swift
//
// Compile-time settings: hotkeys, menu bar icon, clipboard limits, weather,
// calendar, pomodoro, usage stats, and where the workflows file is found. Edit and rebuild to change them.

import Foundation
import Carbon.HIToolbox

// MARK: - Configuration

/// A system-wide shortcut registered through RegisterEventHotKey.
struct HotKey: Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    static let commandShiftSpace = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(cmdKey | shiftKey),
        display: "⌘⇧Space"
    )

    /// macOS 15 and later refuse hotkeys whose only modifiers are Option or
    /// Option+Shift, so this preset only works on macOS 14 and earlier.
    static let optionSpace = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey),
        display: "⌥Space"
    )

    /// Overrides ⌘⌥C inside apps while the launcher runs (Finder's "Copy as
    /// Pathname", the browsers' web inspector).
    static let commandOptionC = HotKey(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(cmdKey | optionKey),
        display: "⌘⌥C"
    )
}

enum Config {
    static let hotKey = HotKey.commandShiftSpace
    static let showMenuBarIcon = true

    /// Opens the clipboard history panel.
    static let clipboardHotKey = HotKey.commandOptionC
    /// Copied items older than this are deleted, from memory and from disk.
    static let clipboardRetention: TimeInterval = 24 * 60 * 60
    /// Oldest items are dropped beyond this count.
    static let clipboardMaxItems = 500
    /// Larger copies are not recorded.
    static let clipboardMaxTextBytes = 256 * 1024
    /// Images larger than this, once encoded as PNG, are not recorded.
    static let clipboardMaxImageBytes = 20 * 1024 * 1024
    /// Images with more pixels than this are turned away before they are
    /// decoded (40 MP is a bit more than an 8K image).
    static let clipboardMaxImagePixels = 40_000_000
    /// macOS has no clipboard-change notification, so the clipboard's change
    /// counter is checked this often (in seconds). The check itself is cheap.
    static let clipboardPollInterval: TimeInterval = 0.5

    /// Where workflows.json is read from, first match wins:
    /// 1. the `ALFRESCO_WORKFLOWS` environment variable;
    /// 2. the `AlfrescoWorkflowsFile` Info.plist key, which build.sh sets to
    ///    the repo's workflows.json;
    /// 3. workflows.json next to the executable (a plain binary built in the
    ///    repo);
    /// 4. ~/.config/alfresco/workflows.json, created on first launch.
    /// The file is re-read whenever it changes, so no rebuild is needed.
    static let workflowsSource: (url: URL, isFallback: Bool) = {
        let fileManager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["ALFRESCO_WORKFLOWS"], !path.isEmpty {
            return (URL(fileURLWithPath: (path as NSString).expandingTildeInPath), false)
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "AlfrescoWorkflowsFile") as? String, !path.isEmpty {
            return (URL(fileURLWithPath: (path as NSString).expandingTildeInPath), false)
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("workflows.json")
            if fileManager.fileExists(atPath: sibling.path) { return (sibling, false) }
        }
        let home = fileManager.homeDirectoryForCurrentUser
        return (home.appendingPathComponent(".config/alfresco/workflows.json"), true)
    }()

    // MARK: Apps

    /// Typing an installed app's name in the launcher opens the app, unless
    /// the input is a workflow keyword. ⌘↩ runs the fallback search instead.
    static let appSearch = true
    /// Searched for .app bundles, each directly and one folder down. A path
    /// ending in .app adds that one app.
    static let appFolders: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices/Applications",
            "/System/Library/CoreServices/Finder.app",
            home.appendingPathComponent("Applications").path,
        ].map { URL(fileURLWithPath: $0) }
    }()
    /// The folders are scanned again when the launcher opens if the last
    /// scan is older than this, so new apps show up without a restart.
    static let appRescanInterval: TimeInterval = 60

    // MARK: Usage stats

    /// Counts how the launcher and the clipboard history are used, in
    /// ~/Library/Application Support/Launcher/usage.json (see UsageStats).
    /// Nothing leaves the Mac. false records nothing and hides "Usage…".
    static let usageTracking = true
    /// Also keeps the first word of multi-word inputs that went to the
    /// fallback (e.g. "jria" from "jria abc-42"), to spot missing or mistyped
    /// keywords. The rest of the input is never kept.
    static let usageTrackFallbackWords = true
    /// Days of counters kept.
    static let usageRetentionDays = 90

    // MARK: Weather

    /// `weather` or `weather <place>` in the launcher shows the forecast
    /// under the input, once a WeatherAPI.com key is set. Enter still opens
    /// whatever workflows.json maps the keyword to.
    static let weatherKeyword = "weather"
    /// WeatherAPI's language for condition text, also used for day names.
    static let weatherLanguage = "fr"
    /// A line above the launcher input always shows the current weather at
    /// home (or where the IP address says you are), once a key is set.
    static let weatherStrip = true
    /// Days shown, today included. The free plan returns at most 3.
    static let weatherDays = 3
    /// Hourly forecast columns shown, starting with the current hour.
    static let weatherHours = 12
    /// Place used for the bare keyword, e.g. "Paris, France". nil locates
    /// the public IP address (WeatherAPI's auto:ip), which can be off by a city.
    static let weatherHomePlace: String? = nil
    /// Forecasts are reused for this long before being fetched again.
    static let weatherCacheLifetime: TimeInterval = 10 * 60

    /// The WeatherAPI.com key (free plan): the `ALFRESCO_WEATHERAPI_KEY`
    /// environment variable, else the first line of
    /// ~/.config/alfresco/weatherapi-key. Re-read each time the launcher
    /// opens. nil turns the weather panel off.
    static func weatherAPIKey() -> String? {
        func clean(_ value: String?) -> String? {
            let line = value?.split(whereSeparator: \.isNewline).first
            let key = line?.trimmingCharacters(in: .whitespaces) ?? ""
            return key.isEmpty ? nil : key
        }
        if let key = clean(ProcessInfo.processInfo.environment["ALFRESCO_WEATHERAPI_KEY"]) {
            return key
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alfresco/weatherapi-key")
        return clean(try? String(contentsOf: file, encoding: .utf8))
    }

    // MARK: Calendar

    /// `cal` in the launcher lists upcoming events from the calendars macOS
    /// Calendar knows (add a Google account in System Settings > Internet
    /// Accounts), `cal <text>` searches them. Needs build/Launcher.app and the
    /// Calendars permission. Enter still opens whatever workflows.json maps
    /// the keyword to.
    static let calendarKeyword = "cal"
    /// Days listed by the bare keyword, today included.
    static let calendarDays = 3
    /// Days searched by `cal <text>`, today included.
    static let calendarSearchDays = 30
    /// Events listed at most; the rest are counted on a last line.
    static let calendarMaxEvents = 8
    /// Account names (System Settings > Internet Accounts, e.g. a Gmail
    /// address) whose calendars are listed. Empty lists every account.
    static let calendarAccounts: [String] = []
    /// Calendar names left out, e.g. ["Jours fériés en France"].
    static let calendarExcluded: [String] = []
    static let calendarHidesBirthdays = true
    /// Leaves out events you declined.
    static let calendarHidesDeclined = true
    /// Events are read again after this long, or as soon as a calendar changes.
    static let calendarCacheLifetime: TimeInterval = 60

    // MARK: Pomodoro

    /// Controlled from the launcher through alfresco://pomodoro/... URLs in
    /// workflows.json (the `pomo` keyword), and shown in the menu bar while
    /// it runs. Lengths in seconds.
    static let pomodoroFocus: TimeInterval = 25 * 60
    static let pomodoroShortBreak: TimeInterval = 5 * 60
    static let pomodoroLongBreak: TimeInterval = 15 * 60
    /// A long break instead of a short one after this many focus sessions.
    static let pomodoroSessionsBeforeLongBreak = 4
    /// When off, a finished focus session leaves its break paused in the
    /// menu bar until you resume it.
    static let pomodoroAutoStartBreaks = true
    /// A sound from /System/Library/Sounds, played when a phase runs out.
    static let pomodoroSound = "Glass"

    /// Used until workflows.json loads, and to seed the ~/.config fallback.
    /// The real workflows live in the repo's workflows.json.
    static let defaultWorkflowsJSON = #"""
        {
          "workflows": [],
          "fallback": {
            "title": "Search Google",
            "url": "https://www.google.com/search?q={query}"
          }
        }

        """#
}
