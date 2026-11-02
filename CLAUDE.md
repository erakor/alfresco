# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

alfresco is a Spotlight-style URL and app launcher for macOS with a 24-hour clipboard history on a second hotkey and a pomodoro timer driven from the launcher. It's a few Swift files under `Sources/` compiled together with `swiftc` (AppKit + Carbon, no Xcode project, no package manager, no dependencies). The keyword → URL mappings live in `workflows.json`, which is data, not code, and is committed to the repo.

## Build & run

Needs the Xcode 16+ Command Line Tools only (Swift 6 compiler, for `-swift-version 6`).

```bash
# Plain binary (finds workflows.json next to itself)
swiftc -O -parse-as-library -swift-version 6 $(find Sources -name '*.swift') -o Launcher && ./Launcher

# .app bundle -> build/Launcher.app (ad-hoc signed, LSUIElement)
./build.sh

# Point a running binary at a specific workflows file
ALFRESCO_WORKFLOWS=/path/to/workflows.json ./Launcher
```

`-parse-as-library` is required because `Sources/App/Launcher.swift` uses `@main`. `-swift-version 6` turns on Swift 6 language mode, so data-race safety violations are compile errors rather than warnings; keep it on every build command. Every `.swift` file under `Sources/` (any depth) is compiled in as one module, so new source files are picked up automatically and folders have no effect on visibility. There is no linter or formatter. The checks are "compiles with `swiftc`" and the runtime self-test (below), both run by CI (`.github/workflows/build.yml`, on a macOS runner). `build/` is gitignored, but a plain `Launcher` binary built in the repo root is not, so don't commit it.

## Self-test

```bash
# Builds the self-test variant and runs it as a plain binary, inside an .app,
# across a relaunch, and held in the menu bar for a screenshot.
Tests/run-self-tests.sh   # log and screenshot in build/self-test/
```

`Tests/SelfTest/` is compiled in only with `-D SELFTEST` (with `Sources/`), so release builds contain none of it. `Launcher --self-test <suite>` (`unit`, `relaunch-write`, `relaunch-read`, `menubar-hold`) skips the single-instance lock and hotkeys, runs the suite inside a real `NSApplication`, prints a `PASS` / `FAIL` line per `check(name, condition)` and exits 0 only if all passed. It requires `ALFRESCO_SUPPORT_DIR` (honored by `ClipboardStore.directory` only in that build), so it never touches the real support folder. Time-dependent code takes an injected clock (`PomodoroTimer(fileURL:now:wakeNotifications:)`, which also takes its own wake notification center, and `UsageStats(fileURL:now:calendar:)`), and alerts go through a `PomodoroAlertSink` the test replaces with a recorder. Accessors that exist only for the test (`PomodoroStatusItem.isShown`, `menuTitles`…, `UsageStats.dayKeys`) are inside `#if SELFTEST`, so release builds keep those members private. The test bundle is built from the same binary with `EXECUTABLE=` and its own `BUNDLE_ID` (`local.launcher.selftest`), so it never registers as the real app. CI writes the PASS/FAIL list to the run summary and uploads the log and a menu bar screenshot. When a change has behavior the self-test can reach, add checks next to the existing ones; in the PR description, add a "Verification" section that links the CI run and lists what was checked by hand (sound, notification banners and real sleep can't be checked on the runner).

## Architecture

Source layout: `Sources/<Feature>/`, one folder per feature. `App/` holds the wiring (`AppDelegate`, `main`, `Config`), `Shared/` holds code used by more than one feature (e.g. `DigitShortcuts`, the ⌘1 to ⌘9 key codes both panels use). Each folder has a user-facing `README.md` (what the feature does, its `Config` settings, its files); the root `README.md` is an overview that links to them, plus build and login-item setup.

### App/Config.swift

`Config` enum holds compile-time settings: both hotkeys (`hotKey`, `clipboardHotKey`), `showMenuBarIcon`, app launching (`appSearch`, `appFolders`, `appRescanInterval`), the clipboard limits (`clipboardRetention`, `clipboardMaxItems`, `clipboardMaxTextBytes`, `clipboardMaxImageBytes`, `clipboardMaxImagePixels`, `clipboardPollInterval`), the weather settings, the pomodoro settings (`pomodoroFocus`, `pomodoroShortBreak`, `pomodoroLongBreak`, `pomodoroSessionsBeforeLongBreak`, `pomodoroAutoStartBreaks`, `pomodoroSound`), the usage stats switches (`usageTracking`, `usageTrackFallbackWords`, `usageRetentionDays`), and `workflowsSource`, which resolves the workflows file in this order: `ALFRESCO_WORKFLOWS` env var → `AlfrescoWorkflowsFile` Info.plist key (written by `build.sh` as the repo's absolute path, so moving the repo requires a rebuild) → `workflows.json` next to the executable → `~/.config/alfresco/workflows.json` (the only location auto-created if missing).

### Launcher/Workflows.swift

- **Workflows** — `Workflow` / `WorkflowSet` are `Decodable` models of `workflows.json`; `ArgumentTransform` parses string transforms like `"stripPrefix:#"`. `WorkflowStore` re-reads the file only when its modification date changes (checked each time the launcher opens) and keeps the last good `WorkflowSet` when a reload fails, exposing `loadError` for the UI.
- **Command parsing** — `CommandParser.parse` splits input into `<keyword> [argument]`. A workflow whose `url` contains `{query}` requires an argument; one without `{query}` matches only the bare keyword. `WorkflowSet.workflow(for:withArgument:)` picks the first workflow of the right form, so one keyword can have both (e.g. `weather` and `weather paris`). Anything else goes to `fallback`. `Command.source` says which (`.workflow(keyword:withArgument:)` with the workflow's first keyword, or `.fallback`), for the usage stats. Arguments are percent-encoded with the RFC 3986 unreserved set. An optional `preview` URL template is expanded the same way into `Command.preview`.

### Launcher/AppIndex.swift

`AppIndex` (main actor) lists the `.app` bundles in `Config.appFolders`, each directly and one folder down, scanned in a detached task at launch and again when the launcher opens if older than `Config.appRescanInterval`. Each `AppEntry` matches on its folded (case/accent-insensitive) Finder display name and file name. `matches(for:limit:openCounts:)` (and `bestMatch`, its first) ranks exact name, name prefix, word prefix (several typed words must start consecutive words), then initials; `openCounts` (bundle ID → opens, from `UsageStats.totals()`) lifts an app by `log2(1 + opens) / 5` tiers, at most 2, so a much-used app can beat a closer name, but an exact name always comes first; ties go to the shorter name, then alphabetical. `AppEntry.bundleID` is read at scan time for this. Apps only take input that would otherwise go to the fallback (`Command.isFallback`), never a workflow keyword.

### Launcher/PreviewFetcher.swift

`PreviewFetcher` (main actor) fetches `Command.preview` for the launcher hint: debounced 400 ms, one request in flight (a new URL cancels the old one, and so does input that no longer has a preview or hiding the panel), 5 s timeout, keeps the first non-empty line of a 2xx non-HTML answer for 10 minutes. Failures are silent. `LauncherController.updateHint` shows `"<text>  ↩ <label>"` once it's cached.

### Weather/

The forecast area under the launcher input, shown while the input is `Config.weatherKeyword` alone or followed by a place, and only when a WeatherAPI.com key is set (`Config.weatherAPIKey()`: `ALFRESCO_WEATHERAPI_KEY`, else `~/.config/alfresco/weatherapi-key`; nil turns the feature off entirely). Enter is unaffected: it still runs the workflow from `workflows.json`.

- `WeatherAPI.swift`: not main-actor. `WeatherLoader.load` makes one `v1/forecast.json` request (`q` is the typed place, `Config.weatherHomePlace`, or `auto:ip` for the bare keyword; `days` is `Config.weatherDays`, at most 3 on the free plan) and builds a `Forecast` (current conditions, `hours` from the current hour slot onward across days, and `days`). Error bodies' codes map to `WeatherError` (1006 unknown place, 2007 quota, 1002/2006/2008 key), whose `message` is shown in the panel.
- `WeatherProvider.swift`: main actor. Turns input into a `WeatherQuery`, debounces typed places (400 ms), runs one load at a time, caches results per query (`Config.weatherCacheLifetime`, failures 30 s), and calls `onUpdate`.
- `WeatherStripView.swift`: the strip above the input; its content (icon, temperature, description, city, today's high / low) is right-aligned in the panel's top-right corner.
- `WeatherView.swift`: the `NSView` (loading, error and forecast states; the forecast is current conditions, a row of `Config.weatherHours` hourly columns, then a compact one-line-per-day row of `Config.weatherDays` days; SF Symbols for WeatherAPI condition codes; the "Powered by WeatherAPI.com" link the free plan requires). Labels are French.

`LauncherController.updateWeather` shows or hides it and resizes the panel with `FloatingPanelController.setHeight`; while it is shown, the one-line hint `preview` is not fetched. It also lays out `WeatherStripView`, the line above the input that shows `WeatherProvider.homeQuery()` whenever `Config.weatherStrip` is on and a key is set: the input row is positioned by a layout guide (`rowGuide`) whose top moves down by the strip's height. Requests go one at a time, the typed query first, then home.

### Shared/HotKeys.swift

Carbon `RegisterEventHotKey`, deliberately avoiding Accessibility/Input Monitoring permissions. Don't switch to `NSEvent` global monitors or CGEventTap. macOS 15+ rejects Option-only hotkeys.

### Shared/UsageStats.swift

`UsageStats.shared` (main actor) keeps local counters in `~/Library/Application Support/Launcher/usage.json`: daily buckets keyed `yyyy-MM-dd` (local time), each a set of name → count maps (`counts`, `keywords`, `fallbackWords`, `clipboardCopies`, `clipboardRestores`, `appsOpened`), keeping the last `Config.usageRetentionDays` calendar days, today included (cutoffs from `firstDayKey(keeping:)`, which counts calendar days so daylight saving doesn't shift them), an unreadable file or one whose `version` isn't 1 set aside as `usage.unreadable.json` (`-2`, `-3`… if that exists, up to `maxSetAsideFiles`; an earlier backup is never replaced, and with every name taken `canSave` turns off saving for that run) rather than overwritten, saved 5 s after a change and on quit, 0600. Simple counters are `UsageCounter` cases (the raw value is the name in the file); weather failures are `weather.failed.<WeatherError.usageName>`. Hooks: `LauncherController` (opened, closed without launching, Enter needing an argument, `recordAppOpened` by bundle ID, `recordLaunch` with `Command.source`), `PreviewFetcher` and `WeatherProvider` (loaded / failed, cancellations not counted), `ClipboardStore.add` (copy by kind and bundle ID), `ClipboardMonitor` (skipped: marked, text, image), `ClipboardController.pickSelected` (restore per bundle ID, restore failed). The menu bar's "Usage…" shows `summary(days:)` in an alert. `totals()` (apps opened and keywords run over every kept day, empty when tracking is off) also ranks the launcher list, so it is read data, not just a report: renaming a key in the file changes the ranking. Never record content: no arguments, queries, clipboard text or file paths. The one exception is the first word of a multi-word fallback input, only when it looks like a keyword (`fallbackWord(in:)`), behind `Config.usageTrackFallbackWords`. Every record call is a no-op when `Config.usageTracking` is false.

### Shared/FloatingPanel.swift

`LauncherPanel` is a borderless non-activating `NSPanel`, so the previously frontmost app stays frontmost. `FloatingPanelController` is the shared base for both panels: frosted background, positioning on the screen under the mouse, fade in/out, dismissal on Esc / click-away / hotkey. `setHeight(_:)` grows or shrinks a panel downward, keeping its top edge where a panel of the original size would sit. Subclasses override hooks (`prepareToShow`, `didHide`, `initialFirstResponder`, `didFocus`, and `handleKeyEquivalent`, which sees ⌘ shortcuts before the panel's standard editing ones) and add views to `contentView`; it also provides shared view factories like `makeHintLabel()`.

### Launcher/LauncherController.swift

`LauncherController` (a `FloatingPanelController`) runs the launcher: the input field, the hint line, the suggestion list, and Enter handling. Enter does nothing when a keyword that needs an argument is typed alone. When `matchedApp()` finds an app and no suggestion row is chosen, the search icon shows the app's icon, the hint reads `↩ Open <app>  ⌘↩ <fallback title>`, Enter opens the app, and ⌘↩ (`handleKeyEquivalent`) runs the fallback search instead. A command whose URL has the `alfresco` scheme is not opened: it goes to the `internalURLHandler` closure from `AppDelegate`, and a `false` result beeps and keeps the bar open. That's how workflows.json reaches in-app features without a schema change.

### Launcher/SuggestionListView.swift

`SuggestionListView` is the list under the input, Alfred-style rows (icon, title, subtitle, and `↩` on the highlighted row or `⌘N` on the first nine). Its rows are `LauncherItem`s: `.app(AppEntry)` and `.workflow(Suggestion)`. `LauncherController.updateSuggestions` fills it with the best matching app first (highlighted from the start, since Enter opens it anyway; ↑ stops there), then `WorkflowSet.suggestions(for:)` (workflows whose keyword starts with a single typed word; empty once the word is every match's whole keyword) reordered by `sortedByUse` (the fully typed keyword first, then most run), then the other `AppIndex.matches`. Both rankings use the `UsageTotals` read in `prepareToShow`, so Enter and the first row always agree. Up to nine rows unless there are more keywords. Workflow icons are the icon of the app that opens the URL, cached per scheme until the list empties. The input keeps focus, so `LauncherController` routes Tab (completes `tabTarget`: the highlighted row, else the first; `LauncherItem.completion` is an app's name or `Suggestion.completion`, which adds a space when the workflow takes an argument), ↑ ↓ (only while the list has rows), and Enter, a click or ⌘1 to ⌘9 (`activate`: an app opens; a workflow is completed, then run if it takes no argument). With no row highlighted, Enter is unchanged. The list sits where the forecast goes and is empty while the forecast is shown; its height is part of `setHeight` in `updateWeather`.

### Pomodoro/

The pomodoro timer. No hotkey or panel: it's controlled through `alfresco://pomodoro/<action>` URLs (the `pomo` workflows in `workflows.json`) and shown in the menu bar.

- `PomodoroTimer.swift`: main actor. `PomodoroState` is `.idle`, `.running(phase, endsAt:)` or `.paused(phase, remaining:)`; `PomodoroPhase` is focus / short break / long break. Time left is always computed from `endsAt`, and a 1 s `Timer` in the `.common` run loop mode runs only while running. `NSWorkspace.didWakeNotification` runs a tick right away, so a phase that ended during sleep alerts on wake. A focus session leads to a break (long after `Config.pomodoroSessionsBeforeLongBreak`), and a break leads to idle. `skip` advances without the alert; `stop` resets the cycle. Every change is saved to `pomodoro.json` in `ClipboardStore.directory` and restored at launch; a phase that ran out meanwhile advances quietly into a paused next phase. `onChange` fires on each change and tick, `onPhaseEnd` when a phase runs out by itself; `connect(to:)` wires both to the status item and `PomodoroAlert`.
- `PomodoroCommand.swift`: parses the URL path (`toggle`, `start`, `pause`, `resume`, `skip`, `stop`, or 1 to 180 minutes); nil makes the launcher beep. `AppDelegate.handleInternalURL` runs it.
- `PomodoroStatusItem.swift`: its own `NSStatusItem`, independent of `Config.showMenuBarIcon`, created while the timer isn't idle and removed when it is. Its `NSMenu` is built once and reused, since a menu item can only be in one menu.
- `PomodoroAlert.swift`: through `PomodoroAlert.sink` (`SystemPomodoroAlertSink`: `NSSound` and `UNUserNotificationCenter`; the self-test swaps in a recorder), plays `Config.pomodoroSound`, and posts a `UNUserNotificationCenter` notification only when `Bundle.main.bundleIdentifier` is set (`UNUserNotificationCenter.current()` raises in the plain binary). The notification calls are kept out of main-actor code because their completion handlers run on a background queue.

### App/Launcher.swift

`AppDelegate` runs as an accessory app, registers both hotkeys, owns the clipboard store/monitor and the pomodoro timer, routes `alfresco://` URLs (`handleInternalURL`), and builds the optional status-bar menu (its "Start Pomodoro" item is disabled through `validateMenuItem` while a session runs). The Workflows submenu is rebuilt in `menuNeedsUpdate`. `LauncherApp.main` first takes an exclusive `flock` on `~/Library/Application Support/Launcher/launcher.lock`; a second copy (plain binary, `build/`, or the installed app) exits with status 0 instead of fighting over the hotkeys and clipboard history.

### Clipboard/ClipboardHistory.swift

- `ClipContent` is the model and the extension point for new kinds: `.text`, `.image(ClipImage)` and `.files([String])` (absolute paths; references only, the files aren't copied). Its on-disk encoding tags each item with a `"kind"` so older builds skip unknown kinds. `ClipItem` records the source app's name and bundle ID (for its icon).
- `ClipboardStore` keeps the history newest-first, prunes items older than the retention window on a timer, saves to `~/Library/Application Support/Launcher/clipboard-history.json` with a debounced save, and calls `onChange` so an open panel can refresh. Image data lives outside the JSON as `clipboard-images/<sha256>.png` (`ClipImage.hash` and the pixel size are validated on decode, because the hash becomes a file name and the size gets multiplied). Another running copy of the app shares that folder, so a save deletes only image files this process referenced and stopped using (`knownImageFiles`); at launch, unused files older than the retention window are swept, which is safe because copying or promoting an image refreshes its file's modification date. Load drops image items whose file is missing, and an unreadable history file is renamed to `clipboard-history.unreadable.json` rather than overwritten. `add` places items by `copiedAt`, since images arrive late.
- `ClipboardMonitor` polls `NSPasteboard.changeCount` (macOS has no clipboard change notification). One copy is recorded as one kind: file URLs, then text, then any image `NSImage` can read, except that an image wins over file URLs that all point to temp/cache locations and over text that is only an http(s) link. `recordImage` reads the bytes and checks the pixel size from the header on the main thread; `ClipImageFile.save` (PNG conversion, hashing, writing; not main-actor) runs in a detached task. It skips items carrying the nspasteboard.org `Concealed` / `Transient` / `AutoGenerated` markers, oversized or whitespace-only text, oversized images, and whatever was on the clipboard at launch.

### Clipboard/ClipboardPanel.swift

`ClipboardController` (a `FloatingPanelController`) shows the history: search field + `NSTableView` (left) filtered via `ClipContent.matches`, and `ClipPreviewView` (right) showing the selected item in full. Row icons are the source app's icon (text), an ImageIO-downsampled thumbnail (images) or the Finder icon (files), cached in an `NSCache` that is emptied when the panel hides. Picking an item (↩, double-click, or ⌘1 to ⌘9 for the first nine rows, matched by key code so other keyboard layouts work) writes it back to the clipboard, moves it to the top, and pastes it: `didHide` calls `PasteKeystroke.post()` (`PasteKeystroke.swift`), which posts ⌘V with `CGEvent` once the panel is gone, using the key that types "v" in the current layout. That needs the Accessibility permission (the hotkeys still don't); without it the first pick of a launch shows the system prompt and the item is only copied. ⌘↩ copies without pasting. Restoring beeps and leaves the clipboard alone if the image file or every referenced file is gone.

## Conventions

- New top-level features (anything with its own hotkey or panel) get a folder under `Sources/` with its own `README.md`, linked from the Features table in the root `README.md`; additions to an existing feature stay in its folder. A user-visible change to a feature updates that folder's `README.md`. Code used by more than one feature goes in `Sources/Shared/` rather than being copied. A folder can hold a single file.
- When changing the `workflows.json` schema, update the decoding in `Workflow`/`WorkflowSet`, the field table in `Sources/Launcher/README.md`, and `Config.defaultWorkflowsJSON` if relevant. Decoding errors are turned into short user-facing messages by `WorkflowStore.describe`.
- New panels should subclass `FloatingPanelController` rather than duplicating panel setup.
- Adding a clip kind means a new `ClipContent` case plus handling in `ClipboardMonitor` (read), `ClipboardController` (display and restore) and `UsageStats.recordClipboardCopy` (a `UsageCounter` for it).
- New usage counters are `UsageCounter` cases recorded through `UsageStats.shared`; anything that would store what the user typed or copied needs its own `Config` switch.
