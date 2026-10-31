# alfresco

A small, Spotlight-style URL launcher for macOS. Press a global hotkey,
type a command, hit Enter, and the URL opens in your default browser. It also
keeps a 24-hour clipboard history on a second hotkey.

- Hotkeys via Carbon `RegisterEventHotKey`: **no Accessibility or Screen Recording permission**.
- Accessory agent: no Dock icon (optional menu bar icon with Open / Clipboard History / Edit Workflows / Quit).
- Workflows live in a JSON file and reload automatically: no rebuild to add one.
- Frosted `NSVisualEffectView` panel, auto-focused input, fade/slide animation.
- `Esc`, clicking outside, or pressing the hotkey again dismisses it.
- `⌘X/C/V/A/Z` work in the input even though the app has no menu bar.

| Input          | Opens                                                             |
| -------------- | ----------------------------------------------------------------- |
| `pr 123`       | `https://github.com/<owner>/<repo>/pull/123` (`pr #123` works too) |
| `jira abc-42`  | `https://understood.atlassian.net/browse/ABC-42`                  |
| `cf 5KsDBWseXY` | `https://app.contentful.com/spaces/p0qf7j048i0q/entries/5KsDBWseXY` |
| `weather`      | `https://wttr.in/?lang=fr&m` (where you are, in French, metric); the hint shows the current weather |
| `weather paris` | `https://wttr.in/paris?lang=fr&m`                                |
| anything else  | `https://www.google.com/search?q=...`                             |

## Workflows

A workflow maps a keyword to a URL. They live in [`workflows.json`](workflows.json)
at the root of this repo. Open it from the menu bar icon (**Edit Workflows…**)
or any editor. Changes apply the next time you open the launcher; no rebuild or
restart needed.

`build.sh` records the absolute path of the repo's `workflows.json` in the app,
so the installed `Launcher.app` keeps reading it from the repo. If you move the
repo, rebuild.

The app looks for the file in this order:

1. The `ALFRESCO_WORKFLOWS` environment variable, if set.
2. The path `build.sh` recorded in `Launcher.app`.
3. `workflows.json` next to the executable (a plain binary built in the repo).
4. `~/.config/alfresco/workflows.json`, created with just the Google fallback
   if nothing else is found.

```json
{
  "workflows": [
    {
      "keywords": ["pr"],
      "title": "GitHub PR",
      "description": "PR by number, e.g. pr 12",
      "url": "https://github.com/your-org/your-repo/pull/{query}",
      "transforms": ["stripPrefix:#"]
    },
    {
      "keywords": ["gh", "github"],
      "title": "GitHub notifications",
      "url": "https://github.com/notifications"
    }
  ],
  "fallback": {
    "title": "Search Google",
    "url": "https://www.google.com/search?q={query}"
  }
}
```

| Field        | Meaning                                                                    |
| ------------ | -------------------------------------------------------------------------- |
| `keywords`   | One or more single words, matched case-insensitively. First match wins. A keyword can be used by two workflows, one with `{query}` and one without: the keyword alone opens the second, the keyword plus an argument the first. |
| `title`      | Shown in the hint as you type.                                              |
| `description` | Optional help text. Shown in the hint when you type the keyword without its argument (Enter does nothing until you add one), and under the workflow in the menu bar's **Workflows** submenu. |
| `url`        | `{query}` is replaced with the percent-encoded argument. Without `{query}`, typing the keyword alone opens the URL. |
| `preview`    | Optional http(s) URL, filled in like `url` (`{query}` only if `url` has it). While the input matches the workflow, the launcher fetches it and shows the first line of the plain-text answer in the hint, e.g. the weather. It waits until you pause typing and keeps answers for 10 minutes; if the request fails, the hint just shows the title. What you type after the keyword is sent to that server. Not allowed on `fallback`. |
| `transforms` | Optional, applied in order to the argument: `uppercase`, `lowercase`, `trim`, `stripPrefix:<text>`, `stripSuffix:<text>`. |
| `fallback`   | Optional. Used when nothing matches; its `url` must contain `{query}`.      |

If the file has a mistake or is missing, the launcher keeps using the last good
version and shows the error in the hint area (hover it for the full message).

The menu bar's **Workflows** submenu lists every workflow with its description;
picking one opens the launcher with its keyword already typed.

## Weather

With a [WeatherAPI.com](https://www.weatherapi.com/pricing.aspx) key (the
free plan is enough, no card needed), typing `weather` or `weather <place>`
opens a forecast under the input: current conditions (temperature,
feels-like, humidity, wind, chance of rain this hour) and three days with
high / low and chance of rain or snow. Enter still opens the `weather`
workflow's page.

1. Create a free account at weatherapi.com and copy your API key from the
   dashboard.
2. Save it, alone on the first line, in `~/.config/alfresco/weatherapi-key`:

   ```bash
   mkdir -p ~/.config/alfresco && pbpaste > ~/.config/alfresco/weatherapi-key && chmod 600 ~/.config/alfresco/weatherapi-key
   ```

   Or set `ALFRESCO_WEATHERAPI_KEY` in the launcher's environment. The key is
   read each time the launcher opens, so no restart is needed.

Without a key the launcher behaves as before, with the one-line `preview` in
the hint.

With a key, a line above the input always shows the current weather where
you are (e.g. "☀️ 14°  Ciel dégagé · Paris" with "↑ 16°  ↓ 8°" on the right;
hover it for the full place). It shares the 10-minute cache with `weather`,
so opening the launcher often costs at most one request every 10 minutes.
Turn it off with `Config.weatherStrip = false`.

- `weather paris`, `weather lyon`, `weather 75011`, `weather cdg`: WeatherAPI
  accepts city names, postal codes, airport codes and `lat,lon`. The place is
  looked up after you pause typing.
- `weather` alone is located from your public IP address (`auto:ip`), shown as
  "position approximative" since it can be off by a city. Set
  `Config.weatherHomePlace` (e.g. `"Paris, France"`) and rebuild to use a
  fixed place instead.
- Text is in French, metric units (`Config.weatherLanguage` sets the language
  of WeatherAPI's condition text and the day names; the panel's own labels
  are French).
- One request per place, reused for 10 minutes (`Config.weatherCacheLifetime`),
  far below the free plan's monthly quota. The free plan forecasts 3 days
  (`Config.weatherDays`).
- "Powered by WeatherAPI.com" in the corner is the link back the free plan
  asks for.

## Clipboard history

Copy and paste with `⌘C` / `⌘V` as usual; the launcher only watches the
clipboard and records each copy: text, images (screenshots, "Copy Image" in a
browser, ...) and files copied in Finder. Press **`⌘⌥C`** to open the history:

- Type to filter, `↑` / `↓` to choose, `↩` (or double-click) to put the item
  back on the clipboard. The panel closes; paste it with `⌘V`.
- `⌘1` to `⌘9` do the same for the first nine rows of the (filtered) list,
  without arrowing down. Each of those rows shows its shortcut on the right.
- `⌘⌫` deletes the selected item. The menu bar icon has **Clear Clipboard History**.
- Each row shows the app it was copied from and how long ago. Images show a
  thumbnail, files their icon.
- The right side previews the selected item: the full text, the image, or the
  file (a picture of it for image files, its icon otherwise) with its path.
- Files are kept as references, not copies: picking a file puts it back on the
  clipboard so `⌘V` in Finder copies it again, but a file that has since been
  moved or deleted can't be restored.
- Items are deleted after **24 hours**. Copying something again, or picking it
  from the history, moves it to the top and restarts its 24 hours.
- History survives quitting and restarting. It is stored, readable only by your
  user, in `~/Library/Application Support/Launcher/clipboard-history.json`,
  with images as PNG files in the `clipboard-images` folder next to it. If the
  history file can't be read, it is renamed to
  `clipboard-history.unreadable.json` and a new history starts.
- Not recorded: passwords and other items that password managers mark as
  private (the [nspasteboard.org](http://nspasteboard.org) `Concealed` /
  `Transient` / `AutoGenerated` markers), whitespace-only text, text larger
  than 256 KB, images over 40 megapixels or larger than 20 MB as PNG, and
  whatever was on the clipboard before the launcher started.
- When a copy holds several kinds at once, one is recorded. Files win, unless
  they are temporary copies of an image that is also on the clipboard (chat
  apps do this), in which case the image is kept. Text wins over an image
  (copying cells in Excel records the text, not a picture of them), unless the
  text is just a web link, as when a browser copies an image with its address.

Notes:

- `⌘⌥C` is global, so while the launcher runs it replaces that shortcut in other
  apps (Finder's "Copy as Pathname", Chrome's and Safari's web inspector).
  Change `Config.clipboardHotKey` if you rely on those.
- Newer macOS versions may ask once whether the launcher may read what you copy
  in other apps ("paste from other apps"). Allow it, or the history stays
  empty.

## Configure

Edit the `Config` enum in `Sources/App/Config.swift`, then rebuild:

- `hotKey`: `.commandShiftSpace` (default) or `.optionSpace`. macOS 15+ rejects
  Option-only hotkeys, so `.optionSpace` only works on macOS 14 and earlier.
- `showMenuBarIcon`: set to `false` for a fully invisible agent.
- `workflowsSource`: how the workflows file is found (see above).
- `clipboardHotKey`: the history shortcut, `.commandOptionC` (`⌘⌥C`) by default.
  Define your own `HotKey(keyCode:modifiers:display:)` with any `kVK_` key code.
- `clipboardRetention` (24 h), `clipboardMaxItems` (500),
  `clipboardMaxTextBytes` (256 KB), `clipboardMaxImageBytes` (20 MB),
  `clipboardMaxImagePixels` (40 MP), `clipboardPollInterval` (0.5 s).

The source lives in `Sources/`, one folder per feature:

- `App/`: `Launcher.swift` (app delegate, menu bar, entry point) and
  `Config.swift` (settings).
- `Launcher/`: `Workflows.swift` (workflows.json model, reloading, command
  parsing) and `LauncherController.swift` (the launcher panel).
- `Clipboard/`: `ClipboardHistory.swift` (clipboard model, storage, watcher) and
  `ClipboardPanel.swift` (history panel).
- `Shared/`: `FloatingPanel.swift` (base class for both panels) and
  `HotKeys.swift` (global hotkeys).

## Build

Needs the Xcode 16+ Command Line Tools (`xcode-select --install`), which include the Swift 6 compiler.

```bash
# Plain binary
swiftc -O -parse-as-library -swift-version 6 $(find Sources -name '*.swift') -o Launcher
./Launcher

# Or an .app bundle (recommended for Login Items)
./build.sh            # -> build/Launcher.app
```

`-parse-as-library` is required because `Sources/App/Launcher.swift` uses `@main`.
The build compiles every `.swift` file under `Sources/`.

## Start automatically at login

**Option A: Login Items (uses the .app)**

```bash
./build.sh
cp -R build/Launcher.app ~/Applications/
open ~/Applications/Launcher.app
```

Then System Settings > General > Login Items > **Open at Login** > `+` and pick
`~/Applications/Launcher.app`.

**Option B: LaunchAgent (works with the plain binary or the .app)**

Run this from the repo folder: `$PWD` in the plist points the agent at this
repo's `workflows.json`.

```bash
mkdir -p ~/Applications ~/Library/LaunchAgents
swiftc -O -parse-as-library -swift-version 6 $(find Sources -name '*.swift') -o ~/Applications/Launcher

cat > ~/Library/LaunchAgents/local.launcher.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.launcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/Applications/Launcher</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ALFRESCO_WORKFLOWS</key>
        <string>$PWD/workflows.json</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.launcher.plist
```

`KeepAlive` restarts it if it crashes but not after you choose Quit. To stop and
remove it:

```bash
launchctl bootout gui/$(id -u)/local.launcher
rm ~/Library/LaunchAgents/local.launcher.plist
```

macOS 13+ shows a one-time "Background Items Added" notification for either
option. If your MDM blocks user LaunchAgents or unsigned binaries (e.g. Santa),
Option A or an allowlist request is the way forward.
