# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

alfresco is a Spotlight-style URL launcher for macOS with a 24-hour clipboard history on a second hotkey. It's a few Swift files under `Sources/` compiled together with `swiftc` (AppKit + Carbon, no Xcode project, no package manager, no dependencies). The keyword → URL mappings live in `workflows.json`, which is data, not code, and is committed to the repo.

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

`-parse-as-library` is required because `Sources/App/Launcher.swift` uses `@main`. `-swift-version 6` turns on Swift 6 language mode, so data-race safety violations are compile errors rather than warnings; keep it on every build command. Every `.swift` file under `Sources/` (any depth) is compiled in as one module, so new source files are picked up automatically and folders have no effect on visibility. There are no tests, linter, or formatter; "compiles with `swiftc`" is the check. `build/` is gitignored, but a plain `Launcher` binary built in the repo root is not, so don't commit it.

## Architecture

Source layout: `Sources/<Feature>/`, one folder per feature. `App/` holds the wiring (`AppDelegate`, `main`, `Config`), `Shared/` holds code used by more than one feature.

### App/Config.swift

`Config` enum holds compile-time settings: both hotkeys (`hotKey`, `clipboardHotKey`), `showMenuBarIcon`, the clipboard limits (`clipboardRetention`, `clipboardMaxItems`, `clipboardMaxTextBytes`, `clipboardMaxImageBytes`, `clipboardMaxImagePixels`, `clipboardPollInterval`), and `workflowsSource`, which resolves the workflows file in this order: `ALFRESCO_WORKFLOWS` env var → `AlfrescoWorkflowsFile` Info.plist key (written by `build.sh` as the repo's absolute path, so moving the repo requires a rebuild) → `workflows.json` next to the executable → `~/.config/alfresco/workflows.json` (the only location auto-created if missing).

### Launcher/Workflows.swift

- **Workflows** — `Workflow` / `WorkflowSet` are `Decodable` models of `workflows.json`; `ArgumentTransform` parses string transforms like `"stripPrefix:#"`. `WorkflowStore` re-reads the file only when its modification date changes (checked each time the launcher opens) and keeps the last good `WorkflowSet` when a reload fails, exposing `loadError` for the UI.
- **Command parsing** — `CommandParser.parse` splits input into `<keyword> [argument]`. A workflow whose `url` contains `{query}` requires an argument; one without `{query}` matches only the bare keyword. `WorkflowSet.workflow(for:withArgument:)` picks the first workflow of the right form, so one keyword can have both (e.g. `weather` and `weather paris`). Anything else goes to `fallback`. Arguments are percent-encoded with the RFC 3986 unreserved set. An optional `preview` URL template is expanded the same way into `Command.preview`.

### Launcher/PreviewFetcher.swift

`PreviewFetcher` (main actor) fetches `Command.preview` for the launcher hint: debounced 400 ms, one request in flight (a new URL cancels the old one, and so does input that no longer has a preview or hiding the panel), 5 s timeout, keeps the first non-empty line of a 2xx non-HTML answer for 10 minutes. Failures are silent. `LauncherController.updateHint` shows `"<text>  ↩ <label>"` once it's cached.

### Weather/

The forecast area under the launcher input, shown while the input is `Config.weatherKeyword` alone or followed by a place, and only when an OpenWeather key is set (`Config.openWeatherAPIKey()`: `ALFRESCO_OPENWEATHER_KEY`, else `~/.config/alfresco/openweather-key`; nil turns the feature off entirely). Enter is unaffected: it still runs the workflow from `workflows.json`.

- `OpenWeather.swift`: not main-actor. `WeatherLoader.load` resolves the place (OpenWeather geocoding, or ipinfo.io for the bare keyword unless `Config.weatherHomePlace` is set), then fetches `data/2.5/weather` and `data/2.5/forecast` (free plan only; no One Call) in parallel and builds a `Forecast`, grouping the 3-hour slots into days in the place's time zone. Errors are `WeatherError`, whose `message` is shown in the panel.
- `WeatherProvider.swift`: main actor. Turns input into a `WeatherQuery`, debounces typed places (400 ms), runs one load at a time, caches results per query (`Config.weatherCacheLifetime`, failures 30 s), and calls `onUpdate`.
- `WeatherView.swift`: the `NSView` (loading, error and forecast states; SF Symbols for OpenWeather icon codes). Labels are French.

`LauncherController.updateWeather` shows or hides it and resizes the panel with `FloatingPanelController.setHeight`; while it is shown, the one-line hint `preview` is not fetched.

### Shared/HotKeys.swift

Carbon `RegisterEventHotKey`, deliberately avoiding Accessibility/Input Monitoring permissions. Don't switch to `NSEvent` global monitors or CGEventTap. macOS 15+ rejects Option-only hotkeys.

### Shared/FloatingPanel.swift

`LauncherPanel` is a borderless non-activating `NSPanel`, so the previously frontmost app stays frontmost. `FloatingPanelController` is the shared base for both panels: frosted background, positioning on the screen under the mouse, fade in/out, dismissal on Esc / click-away / hotkey. `setHeight(_:)` grows or shrinks a panel downward, keeping its top edge where a panel of the original size would sit. Subclasses override hooks (`prepareToShow`, `didHide`, `initialFirstResponder`, `didFocus`, and `handleKeyEquivalent`, which sees ⌘ shortcuts before the panel's standard editing ones) and add views to `contentView`; it also provides shared view factories like `makeHintLabel()`.

### Launcher/LauncherController.swift

`LauncherController` (a `FloatingPanelController`) runs the URL launcher: the input field, the hint line, and Enter handling. Enter does nothing when a keyword that needs an argument is typed alone.

### App/Launcher.swift

`AppDelegate` runs as an accessory app, registers both hotkeys, owns the clipboard store/monitor, and builds the optional status-bar menu. The Workflows submenu is rebuilt in `menuNeedsUpdate`. `LauncherApp.main` first takes an exclusive `flock` on `~/Library/Application Support/Launcher/launcher.lock`; a second copy (plain binary, `build/`, or the installed app) exits with status 0 instead of fighting over the hotkeys and clipboard history.

### Clipboard/ClipboardHistory.swift

- `ClipContent` is the model and the extension point for new kinds: `.text`, `.image(ClipImage)` and `.files([String])` (absolute paths; references only, the files aren't copied). Its on-disk encoding tags each item with a `"kind"` so older builds skip unknown kinds. `ClipItem` records the source app's name and bundle ID (for its icon).
- `ClipboardStore` keeps the history newest-first, prunes items older than the retention window on a timer, saves to `~/Library/Application Support/Launcher/clipboard-history.json` with a debounced save, and calls `onChange` so an open panel can refresh. Image data lives outside the JSON as `clipboard-images/<sha256>.png` (`ClipImage.hash` and the pixel size are validated on decode, because the hash becomes a file name and the size gets multiplied). Another running copy of the app shares that folder, so a save deletes only image files this process referenced and stopped using (`knownImageFiles`); at launch, unused files older than the retention window are swept, which is safe because copying or promoting an image refreshes its file's modification date. Load drops image items whose file is missing, and an unreadable history file is renamed to `clipboard-history.unreadable.json` rather than overwritten. `add` places items by `copiedAt`, since images arrive late.
- `ClipboardMonitor` polls `NSPasteboard.changeCount` (macOS has no clipboard change notification). One copy is recorded as one kind: file URLs, then text, then any image `NSImage` can read, except that an image wins over file URLs that all point to temp/cache locations and over text that is only an http(s) link. `recordImage` reads the bytes and checks the pixel size from the header on the main thread; `ClipImageFile.save` (PNG conversion, hashing, writing; not main-actor) runs in a detached task. It skips items carrying the nspasteboard.org `Concealed` / `Transient` / `AutoGenerated` markers, oversized or whitespace-only text, oversized images, and whatever was on the clipboard at launch.

### Clipboard/ClipboardPanel.swift

`ClipboardController` (a `FloatingPanelController`) shows the history: search field + `NSTableView` (left) filtered via `ClipContent.matches`, and `ClipPreviewView` (right) showing the selected item in full. Row icons are the source app's icon (text), an ImageIO-downsampled thumbnail (images) or the Finder icon (files), cached in an `NSCache` that is emptied when the panel hides. Picking an item (↩, double-click, or ⌘1 to ⌘9 for the first nine rows, matched by key code so other keyboard layouts work) writes it back to the clipboard and moves it to the top; it does not paste. Restoring beeps and leaves the clipboard alone if the image file or every referenced file is gone.

## Conventions

- New top-level features (anything with its own hotkey or panel) get a folder under `Sources/`; additions to an existing feature stay in its folder. Code used by more than one feature goes in `Sources/Shared/` rather than being copied. A folder can hold a single file.
- When changing the `workflows.json` schema, update the decoding in `Workflow`/`WorkflowSet`, the field table in `README.md`, and `Config.defaultWorkflowsJSON` if relevant. Decoding errors are turned into short user-facing messages by `WorkflowStore.describe`.
- New panels should subclass `FloatingPanelController` rather than duplicating panel setup.
- Adding a clip kind means a new `ClipContent` case plus handling in `ClipboardMonitor` (read) and `ClipboardController` (display and restore).
