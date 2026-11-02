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

    /// Spotlight's shortcut: turn it off for Spotlight first (System Settings >
    /// Keyboard > Keyboard Shortcuts > Spotlight), or registering it fails.
    static let commandSpace = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(cmdKey),
        display: "⌘Space"
    )

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
    static let hotKey = HotKey.commandSpace
    static let showMenuBarIcon = true

    /// Opens the clipboard history panel.
    static let clipboardHotKey = HotKey.commandOptionC
    /// Copied items older than this are deleted, from memory and from disk.
    static let clipboardRetention: TimeInterval = 24 * 60 * 60
    /// Oldest items are dropped beyond this count. Pinned items don't count.
    static let clipboardMaxItems = 500
    /// Pinning more than this many items beeps instead.
    static let clipboardMaxPinnedItems = 100
    /// Of those, at most this many images (up to clipboardMaxImageBytes
    /// each, kept on disk for as long as they're pinned).
    static let clipboardMaxPinnedImages = 10
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
    /// Copies made while one of these apps is in front are not recorded, for
    /// apps that hold secrets but don't mark them on the clipboard (apps that
    /// do are skipped anyway, see ClipboardMonitor.ignoredTypes). Bundle IDs,
    /// e.g. "com.googlecode.iterm2" to keep nothing copied in a terminal.
    /// Best effort: macOS doesn't say which app made a copy, so this is the
    /// app in front when the clipboard is next checked (up to
    /// clipboardPollInterval later). A copy from a menu bar extra or an
    /// autofill popup, which leaves another app in front, isn't caught, and
    /// switching apps right after copying can catch the wrong one.
    static let clipboardIgnoredApps: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

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
    /// The URL schemes a workflow's `url` may use; workflows.json doesn't load
    /// with any other. Enter opens the URL, and a file: URL would run a local
    /// script or app, so an edit to workflows.json alone (a data file, read
    /// live from the repo) can't do more than open web pages. To use an app's
    /// own scheme in a workflow, add it here (lowercase) and rebuild.
    static let workflowURLSchemes: Set<String> = ["alfresco", "http", "https", "mailto"]
    /// Typed before every workflows.json keyword: `/pr 12`, `/cal`, `/zz`.
    /// Keywords in the file are written without it. Bare words then only go
    /// to apps, built-ins and the fallback search, so a command never runs
    /// by accident, and input starting with it never goes anywhere else
    /// (an unknown command beeps). The prefix alone, or followed by
    /// `commandListKeyword`, lists every command. nil types keywords bare,
    /// with no list. It must not overlap `calculatorPrefix` (neither may
    /// start with the other), or the calculator's input would be taken as
    /// a command; the self-test checks this.
    static let commandPrefix: String? = "/"
    /// `/help` lists every command, like `/` alone, unless a workflow uses
    /// this keyword itself.
    static let commandListKeyword = "help"

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

    // MARK: Built-ins

    /// Answers the launcher works out itself, shown in the hint and copied
    /// with Enter (see Sources/BuiltIns). A workflow keyword always wins over
    /// them. nil turns one off.
    /// `= 3*14`, `= 2^10`, `= 10 km in mi`: a calculation or unit conversion.
    static let calculatorPrefix: String? = "="
    /// `time tokyo`, `time 15:00 in tokyo`, `time 9am new york in paris`.
    /// `time` alone is left to apps (Time Machine) and the search.
    static let timeKeyword: String? = "time"
    /// `uuid`: a new random UUID, lowercase.
    static let uuidKeyword: String? = "uuid"
    /// `now`, `now utc`, `now unix`, `now ms`, `now date`: the current time.
    static let timestampKeyword: String? = "now"

    // MARK: Usage stats

    /// Counts how the launcher and the clipboard history are used, in
    /// ~/Library/Application Support/Launcher/usage.json (see UsageStats).
    /// Nothing leaves the Mac. false records nothing and hides "Usage…".
    static let usageTracking = true
    /// Also keeps the first word of multi-word inputs that went to the
    /// fallback when it is a keyword or a typo away from one of 4 letters or
    /// more (e.g. "jria" from "jria abc-42"), to spot mistyped keywords. Any
    /// other word, and the rest of the input, is never kept.
    static let usageTrackFallbackWords = true
    /// Days of counters kept.
    static let usageRetentionDays = 90

    // MARK: Weather

    /// `/weather` or `/weather <place>` in the launcher shows the forecast
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
        #if SELFTEST
        // The self-test never uses a real key, even one exported in the
        // shell: a launcher it drives would fetch the forecast with it.
        return nil
        #else
        if let key = clean(ProcessInfo.processInfo.environment["ALFRESCO_WEATHERAPI_KEY"]) {
            return key
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alfresco/weatherapi-key")
        return clean(try? String(contentsOf: file, encoding: .utf8))
        #endif
    }

    // MARK: Calendar

    /// `/cal` in the launcher lists upcoming events from the calendars macOS
    /// Calendar knows (add a Google account in System Settings > Internet
    /// Accounts), `/cal <text>` searches them. Needs build/Launcher.app and the
    /// Calendars permission. Enter still opens whatever workflows.json maps
    /// the keyword to.
    static let calendarKeyword = "cal"
    /// Days listed by the bare keyword, today included.
    static let calendarDays = 3
    /// Days searched by `/cal <text>`, today included.
    static let calendarSearchDays = 30
    /// Events listed at most by `/cal <text>`; the rest are counted on a last
    /// line. (`/cal` shows the next event, then up to 4 per column.)
    static let calendarMaxEvents = 8
    /// Account names (System Settings > Internet Accounts, e.g. a Gmail
    /// address) whose calendars are listed. Empty lists every account.
    static let calendarAccounts: [String] = []
    /// Calendar names left out, e.g. ["Jours fériés en France"].
    static let calendarExcluded: [String] = []
    static let calendarHidesBirthdays = true
    /// Leaves out events you declined.
    static let calendarHidesDeclined = true
    /// Events are read again after this long; a change in a calendar
    /// (EKEventStoreChanged) refreshes them at once anyway.
    static let calendarCacheLifetime: TimeInterval = 5 * 60

    // MARK: Pomodoro

    /// Controlled from the launcher through alfresco://pomodoro/... URLs in
    /// workflows.json (the `/pomo` keyword), and shown in the menu bar while
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
