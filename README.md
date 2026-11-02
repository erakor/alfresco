# alfresco

A small, Spotlight-style URL launcher for macOS. Press a global hotkey,
type a command, hit Enter, and the URL opens in your default browser. Type an
app's name instead and it opens the app. It also keeps a 24-hour clipboard
history on a second hotkey, and runs a pomodoro timer you start from the
launcher.

- Hotkeys via Carbon `RegisterEventHotKey`: **no Accessibility or Screen Recording permission**.
- Accessory agent: no Dock icon (optional menu bar icon with Open / Clipboard History / Edit Workflows / Quit).
- Workflows live in a JSON file and reload automatically: no rebuild to add one.
- Frosted `NSVisualEffectView` panel, auto-focused input, fade/slide animation.
- `Esc`, clicking outside, or pressing the hotkey again dismisses it.
- `⌘X/C/V/A/Z` work in the input even though the app has no menu bar.
- Suggestions as you type, with icons: matching apps and keywords (`p` lists `pr`); `Tab` completes, `↑` `↓` choose, `⌘1` to `⌘9` pick.

| Input          | Opens                                                             |
| -------------- | ----------------------------------------------------------------- |
| `pr 123`       | `https://github.com/<owner>/<repo>/pull/123` (`pr #123` works too) |
| `jira abc-42`  | `https://understood.atlassian.net/browse/ABC-42`                  |
| `cf 5KsDBWseXY` | `https://app.contentful.com/spaces/p0qf7j048i0q/entries/5KsDBWseXY` |
| `weather`      | `https://wttr.in/?lang=fr&m` (where you are, in French, metric); the hint shows the current weather |
| `weather paris` | `https://wttr.in/paris?lang=fr&m`                                |
| `saf`, `code`, `vsc` | The installed app whose name matches (Safari, Visual Studio Code) |
| `pomo`         | Starts a 25 min [pomodoro](#pomodoro), or pauses / resumes it (nothing opens) |
| anything else  | `https://www.google.com/search?q=...`                             |

## Apps

When what you type isn't a workflow keyword, the launcher looks for an
installed app with that name. The hint shows `↩ Open Safari` and the
magnifying glass turns into the app's icon; Enter opens the app (or brings it
forward if it's already running). Press `⌘↩` to search for the text instead.

- Matching ignores case and accents, and picks, in order: the exact name, a
  name starting with what you typed (`saf`), a word of the name (`code`,
  `studio code` for Visual Studio Code), then the initials (`vsc`). Ties go
  to the shorter name.
- Both the name Finder shows and the file name count, so system apps match
  in English and in your language (`calculator` and `calculatrice`).
- Workflow keywords always win: `weather` runs the `weather` workflow, not
  the Weather app. Only the whole keyword counts, so `weath` opens the app.
- Apps are found in `/Applications`, `/System/Applications`,
  `/System/Library/CoreServices/Applications` and `~/Applications`, each with
  one level of subfolders (`Utilities`), plus Finder. The list is refreshed
  when the launcher opens, at most once a minute, so new apps show up
  without a restart.

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
| `url`        | `{query}` is replaced with the percent-encoded argument. Without `{query}`, typing the keyword alone opens the URL. An `alfresco://` URL is run by the launcher itself instead of being opened (see [Pomodoro](#pomodoro)); one it doesn't know beeps. |
| `preview`    | Optional http(s) URL, filled in like `url` (`{query}` only if `url` has it). While the input matches the workflow, the launcher fetches it and shows the first line of the plain-text answer in the hint, e.g. the weather. It waits until you pause typing and keeps answers for 10 minutes; if the request fails, the hint just shows the title. What you type after the keyword is sent to that server. Not allowed on `fallback`. |
| `transforms` | Optional, applied in order to the argument: `uppercase`, `lowercase`, `trim`, `stripPrefix:<text>`, `stripSuffix:<text>`. |
| `fallback`   | Optional. Used when nothing matches; its `url` must contain `{query}`.      |

If the file has a mistake or is missing, the launcher keeps using the last good
version and shows the error in the hint area (hover it for the full message).

The menu bar's **Workflows** submenu lists every workflow with its description;
picking one opens the launcher with its keyword already typed.

### Suggestions

A list under the input shows what you could mean, one row each with an icon,
a title and a subtitle:

- The installed apps whose name matches (with their path), best match first.
  That first app is highlighted because `Enter` opens it; `⌘↩` searches instead.
- While you type a single word, the workflows whose keyword starts with it
  (`p` shows `pr`), with their keyword and description. Their icon is the app
  that opens the URL (your browser for web links).

Up to nine rows show (more keywords scroll). The highlighted row shows `↩`,
the others `⌘2` to `⌘9`: that shortcut takes the row directly. `↑` `↓` move
the highlight. `Tab` completes the highlighted row, else the first, adding a
space when a workflow needs an argument so you can keep typing. `Enter` (or a
click, or `⌘N`) on a workflow row completes it and opens it if it needs
nothing more; on an app row it opens the app. With no row highlighted,
`Enter` runs what is typed, as before (so `p` alone still searches Google
when no app matches). The workflow rows go away once the word is a whole
keyword or you type a space.

## Weather

With a [WeatherAPI.com](https://www.weatherapi.com/pricing.aspx) key (the
free plan is enough, no card needed), typing `weather` or `weather <place>`
opens a forecast under the input: current conditions (temperature,
feels-like, humidity, wind, chance of rain this hour), the next 12 hours
(temperature, icon, chance of rain or snow; `Config.weatherHours`), and below
them a compact line with three days' high / low and chance of rain or snow. Enter still opens the `weather`
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

With a key, the launcher's top-right corner, above the input, always shows
the current weather where you are (e.g. "☀️ 14°  Ciel dégagé · Paris
↑ 16°  ↓ 8°"; hover it for the full place). It shares the 10-minute cache with `weather`,
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

## Pomodoro

Type `pomo` in the launcher and press Enter to start a 25 minute focus
session. The countdown shows in the menu bar (a timer icon for focus, a cup
for breaks) for as long as a session or break is under way, and disappears
when it's over. Its menu shows where you are in the cycle ("Focus 2 of 4,
18:42 left") and has Pause / Resume, Skip and Stop.

| Input        | Does                                                                  |
| ------------ | --------------------------------------------------------------------- |
| `pomo`       | Starts a focus session, or pauses / resumes the one running           |
| `pomo 50`    | Starts a 50 minute focus session (1 to 180), replacing any running one |
| `pomo pause`, `pomo resume` | Pause or resume                                        |
| `pomo skip`  | Ends the focus session or break now, without the alert                |
| `pomo stop`  | Stops, and the cycle starts over                                      |

- After a focus session comes a 5 minute break, or a 15 minute one after
  every 4th session. The break starts by itself. When it ends the timer stops
  until you type `pomo` again.
- When a session or break runs out, a sound plays (`Glass`). When you run
  `build/Launcher.app`, a macOS notification is shown too. macOS asks once
  for permission the first time you start a session. The plain `./Launcher`
  binary only plays the sound, since notifications need an app bundle.
- The timer is saved in `~/Library/Application Support/Launcher/pomodoro.json`,
  so quitting or rebuilding mid-session keeps the countdown going. A phase
  that ran out while the app was closed moves on to the next one, paused.
- The `pomo` keyword is two ordinary workflows in `workflows.json` pointing at
  `alfresco://pomodoro/toggle` and `alfresco://pomodoro/{query}`. Rename the
  keyword or add others (say `focus` → `alfresco://pomodoro/50`) there.
  The actions are `toggle`, `start`, `pause`, `resume`, `skip`, `stop` and a
  number of minutes.
- Lengths, the cycle, the sound and whether breaks start by themselves are in
  `Config` (see [Configure](#configure)).

## Clipboard history

Copy and paste with `⌘C` / `⌘V` as usual; the launcher only watches the
clipboard and records each copy: text, images (screenshots, "Copy Image" in a
browser, ...) and files copied in Finder. Press **`⌘⌥C`** to open the history:

- Type to filter, `↑` / `↓` to choose, `↩` (or double-click) to paste the
  item into the app you were using. It is also put back on the clipboard.
- `⌘1` to `⌘9` do the same for the first nine rows of the (filtered) list,
  without arrowing down. Each of those rows shows its shortcut on the right.
- `⌘↩` only puts the selected item back on the clipboard, without pasting.
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
- Pasting needs the **Accessibility** permission (System Settings > Privacy &
  Security > Accessibility), because it types `⌘V` into the other app. The
  first pick without it shows the system prompt and only copies the item;
  until you allow it, paste with `⌘V` yourself. `build.sh` signs the app
  ad hoc, so macOS may forget the permission after a rebuild: remove the
  launcher from that list and add it again.
- Newer macOS versions may ask once whether the launcher may read what you copy
  in other apps ("paste from other apps"). Allow it, or the history stays
  empty.

## Usage stats

The launcher counts how it is used, so you can see which keywords earn their
place and what is missing. Everything stays on your Mac, in
`~/Library/Application Support/Launcher/usage.json` (readable only by your
user), one bucket per day, kept for 90 days. The menu bar's **Usage…** shows the
last 30 days and can reveal the file.

Recorded:

- Launcher: how often it opens, how often it closes without opening anything
  (and whether something was typed), Enter on a keyword still missing its
  argument, each workflow run (by its first keyword: `pr` or `pr …`, never what
  you typed after it), how many installed apps were opened (not which), and
  how often the fallback is used.
- The first word of multi-word fallback inputs, lowercased, if it looks like a
  keyword (letters, digits, `-`, `_`, up to 20 characters): `jria abc-42` keeps
  `jria`, a mistyped `jira`. The rest of the input is never kept.
- Previews and weather: answers received and failures, by kind of error.
- Clipboard: copies by kind, copies and restores per app (by bundle ID), and
  skipped copies by reason. Never any content or file path.

`usageTracking = false` in `Config.swift` turns it off (and hides **Usage…**);
`usageTrackFallbackWords = false` keeps the counts but drops the fallback words.

## Configure

Edit the `Config` enum in `Sources/App/Config.swift`, then rebuild:

- `hotKey`: `.commandShiftSpace` (default) or `.optionSpace`. macOS 15+ rejects
  Option-only hotkeys, so `.optionSpace` only works on macOS 14 and earlier.
- `showMenuBarIcon`: set to `false` for a fully invisible agent.
- `workflowsSource`: how the workflows file is found (see above).
- `clipboardHotKey`: the history shortcut, `.commandOptionC` (`⌘⌥C`) by default.
  Define your own `HotKey(keyCode:modifiers:display:)` with any `kVK_` key code.
- `appSearch`: set to `false` to turn app launching off. `appFolders` lists
  where apps are looked for, `appRescanInterval` (60 s) how often.
- `clipboardRetention` (24 h), `clipboardMaxItems` (500),
  `clipboardMaxTextBytes` (256 KB), `clipboardMaxImageBytes` (20 MB),
  `clipboardMaxImagePixels` (40 MP), `clipboardPollInterval` (0.5 s).
- `pomodoroFocus` (25 min), `pomodoroShortBreak` (5 min), `pomodoroLongBreak`
  (15 min), `pomodoroSessionsBeforeLongBreak` (4), `pomodoroAutoStartBreaks`
  (`true`; when `false`, a break waits paused in the menu bar until you resume
  it), `pomodoroSound` (`"Glass"`, any name from `/System/Library/Sounds`).
- `usageTracking`, `usageTrackFallbackWords`, `usageRetentionDays` (90): see
  [Usage stats](#usage-stats).

The source lives in `Sources/`, one folder per feature:

- `App/`: `Launcher.swift` (app delegate, menu bar, entry point) and
  `Config.swift` (settings).
- `Launcher/`: `Workflows.swift` (workflows.json model, reloading, command
  parsing), `AppIndex.swift` (installed apps and name matching) and
  `LauncherController.swift` (the launcher panel).
- `Clipboard/`: `ClipboardHistory.swift` (clipboard model, storage, watcher) and
  `ClipboardPanel.swift` (history panel).
- `Pomodoro/`: `PomodoroTimer.swift` (the timer), `PomodoroCommand.swift`
  (`alfresco://pomodoro/...` URLs), `PomodoroStatusItem.swift` (menu bar
  countdown) and `PomodoroAlert.swift` (sound and notification).
- `Shared/`: `FloatingPanel.swift` (base class for both panels),
  `HotKeys.swift` (global hotkeys) and `UsageStats.swift` (usage counters).

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
