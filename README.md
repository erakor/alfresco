# alfresco

A small, Spotlight-style URL launcher for macOS. Press a global hotkey,
type a command (`/pr 12`; `/` lists them all), hit Enter, and the URL opens
in your default browser. Type an app's name instead and it opens the app.
Type `/cal` to see your upcoming events (Google calendars included), or `= 3*14` to calculate. It also keeps a 24-hour clipboard
history on a second hotkey, runs a pomodoro timer you start from the
launcher, and can sleep or lock the Mac.

- Hotkeys via Carbon `RegisterEventHotKey`: **no Accessibility or Screen Recording permission**.
- Accessory agent: no Dock icon (optional menu bar icon with Open / Clipboard History / Edit Workflows / Launch at Login / Quit).
- Workflows live in a JSON file and reload automatically: no rebuild to add one.
- Frosted `NSVisualEffectView` panel, auto-focused input, fade/slide animation.
- Commands start with `/`, so a bare word never runs one by accident; `/` or `/help` lists them all.
- Suggestions as you type, with icons: matching apps, and commands after `/` (`/p` lists `/pr`); `Tab` completes, `↑` `↓` choose, `⌘1` to `⌘9` pick.
- Your commands as [cards](Sources/Launcher/README.md#command-cards) under the empty input, the most used first; click one to type it.

| Input          | Opens                                                             |
| -------------- | ----------------------------------------------------------------- |
| `/` or `/help` | Nothing: lists every [command](Sources/Launcher/README.md#commands) |
| `/pr 123`      | `https://github.com/<owner>/<repo>/pull/123` (`/pr #123` works too) |
| `/jira abc-42` | `https://understood.atlassian.net/browse/ABC-42`                  |
| `/cf 5KsDBWseXY` | `https://app.contentful.com/spaces/p0qf7j048i0q/entries/5KsDBWseXY` |
| `/weather`     | `https://wttr.in/?lang=fr&m` (where you are, in French, metric); the hint shows the current weather |
| `/weather paris` | `https://wttr.in/paris?lang=fr&m`                               |
| `/cal`         | `https://calendar.google.com/calendar/r`; the launcher lists your next [events](Sources/Calendar/README.md) |
| `/cal standup` | Google Calendar's search for `standup`; the launcher lists the matching events |
| `/cal demain`  | Google Calendar; the launcher lists tomorrow's events (also `lundi`, `12/11`, `25 dec`) |
| `saf`, `code`, `vsc` | The installed app whose name matches (Safari, Visual Studio Code) |
| `/pomo`        | Starts a 25 min [pomodoro](Sources/Pomodoro/README.md), or pauses / resumes it (nothing opens); the launcher shows the timer and the hint says what Enter will do |
| `/zz`, `/lockscreen`, `/displaysleep` | Puts the Mac to sleep, locks the screen, or turns the display off ([System](Sources/System/README.md)) |
| `/stats`       | Nothing: the launcher shows this week's [usage](Sources/Stats/README.md) (top commands and apps, clips restored, focus sessions, commands never run); Enter opens the 30-day summary |
| `= 3*14`, `= 10 km in mi` | Nothing: the hint shows the [answer](Sources/BuiltIns/README.md) (`42`) and Enter copies it |
| `time tokyo`, `time 15:00 in tokyo` | Nothing: the time there, copied with Enter |
| `uuid`, `now`  | Nothing: Enter copies a new UUID, or the current time in ISO 8601 |
| anything else  | `https://www.google.com/search?q=...`                             |

## Features

Each feature has its own README, next to its code in `Sources/`:

| Feature | What it does |
| ------- | ------------ |
| [Launcher](Sources/Launcher/README.md) | The `⌘Space` bar: workflows (`workflows.json`, its format and where it is read from), `/` commands and their suggestions, and opening apps by name. |
| [Weather](Sources/Weather/README.md) | The forecast under the input for `/weather` / `/weather <place>`, and the current weather above it. Needs a free WeatherAPI.com key. |
| [Calendar](Sources/Calendar/README.md) | Your upcoming events under the input for `/cal`, one day's with `/cal demain` or `/cal 12/11`, and a search with `/cal <text>`, read from macOS Calendar (Google accounts included). Needs `build/Launcher.app`. |
| [Built-ins](Sources/BuiltIns/README.md) | Answers in the launcher's hint, copied with Enter: a calculator and unit converter (`= 3*14`, `= 10 km in mi`), time zones (`time tokyo`), a new UUID (`uuid`), the current time (`now`) and dates (`days until 25/12`, `= today + 30 days`, `week`). |
| [Pomodoro](Sources/Pomodoro/README.md) | A focus / break timer started with `/pomo`, counting down in the menu bar. |
| [System](Sources/System/README.md) | `/zz` (sleep), `/lockscreen` and `/displaysleep` from the launcher, with no permission prompt. |
| [Stats](Sources/Stats/README.md) | `/stats`: your last 7 days under the input (top commands and apps, clips restored, focus sessions) and the commands nobody runs. |
| [Clipboard history](Sources/Clipboard/README.md) | 24 hours of copied text, images and files on `⌘⌥C`, pasted back into the app you were using. Pinned items stay on top and never expire. |
| [Shared](Sources/Shared/README.md) | Local usage stats (menu bar **Usage…**), plus the hotkeys and the panel the features share. |
| [App](Sources/App/README.md) | The wiring: menu bar, hotkey registration, `alfresco://` URLs, single instance, and `Config`. |

## Configure

Settings are compile-time: edit the `Config` enum in `Sources/App/Config.swift`,
then rebuild. Each feature's README lists the settings it uses; the most common
ones are:

- `hotKey`: `.commandSpace` (default; turn Spotlight's ⌘Space off first),
  `.commandShiftSpace` or `.optionSpace` (macOS 14 and earlier only).
  See [Launcher](Sources/Launcher/README.md#settings).
- `clipboardHotKey`: `⌘⌥C` by default. See
  [Clipboard history](Sources/Clipboard/README.md#settings).
- `showMenuBarIcon`: set to `false` for a fully invisible agent.

## Build

Needs the Xcode 16+ Command Line Tools (`xcode-select --install`), which include the Swift 6 compiler.

```bash
# Plain binary
swiftc -O -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos12.0" $(find Sources -name '*.swift') -o Launcher
./Launcher

# Or an .app bundle
./build.sh            # -> build/Launcher.app (./install.sh to install it, below)
```

`-parse-as-library` is required because `Sources/App/Launcher.swift` uses `@main`.
The build compiles every `.swift` file under `Sources/`.

The app icon is `Resources/AppIcon.png` (1024 px), which `build.sh` turns into
the bundle's `AppIcon.icns`; the plain binary has none. To change it, edit
`Resources/AppIcon.svg` and export it again as a 1024 × 1024 PNG with a
transparent background, for example by opening it in a browser and taking a
screenshot of it, or with any vector editor.

`./Launcher --check workflows.json` checks a workflows file and exits (see
[Checking the file](Sources/Launcher/README.md#checking-the-file)).

## Measuring performance

The app marks its slow-prone work with signpost intervals (subsystem
`local.launcher`, the bundle ID; category `performance`; defined in
`Sources/Shared/Signposts.swift`). They cost next to nothing until something
records them, and carry only counts, sizes and kinds, never what you typed or
copied (a search field's text is reduced to its length).

| Interval | What it covers |
| --- | --- |
| `clipboard.store.init`, `clipboard.load` (`.decode`) | Reading the history at launch |
| `clipboard.save` (`.encode`, `.write`) | Writing the history, 1 s after the last change |
| `clipboard.poll` | A clipboard change being read (`kind=`) |
| `clipboard.image.save` | Converting and storing a copied image (background) |
| `clipboard.open`, `clipboard.reload`, `clipboard.filter` | Opening the history panel and each keystroke in it |
| `clipboard.preview`, `thumbnail.decode`, `thumbnail.hit` / `.miss` | The selected item's preview and the picture decodes (background) |
| `clipboard.restore.write` | Putting an item back on the clipboard |
| `launcher.input`, `apps.match`, `apps.scan` | Each keystroke in the launcher, app ranking, the app scan (background) |
| `store.load`, `store.save` | Reading and writing `usage.json` and `typed-picks.json` (`kind=usage` or `typedAppPicks`, `bytes=`) |
| `calendar.fetch`, `calendar.storeChanged` | Reading events (background); each change macOS reports |
| `stats.report` | Adding up the usage stats as `/stats` appears |
| `weather.load`, `preview.load` | Network requests (`kind=ok`, `failed` or `cancelled`) |

**Without Xcode**, watch them live while you use the app, one line per
interval with its duration:

```bash
Tests/signposts.sh                       # every interval
SIGNPOSTS_MIN_MS=8 Tests/signposts.sh    # only the ones that could cost a frame (no point events)
```

It reads `/usr/bin/log stream --signpost --style ndjson` and pairs each begin
with its end by signpost ID. In zsh, type `/usr/bin/log` in full if you use
`log` yourself: zsh has a `log` builtin.

**With Xcode** (Instruments), record a trace while you go through what you
want to measure, then open it:

```bash
xcrun xctrace record --template 'Time Profiler' --instrument os_signpost \
  --attach "$(pgrep -f build/Launcher.app/Contents/MacOS/Launcher)" \
  --time-limit 30s --output launcher.trace
open launcher.trace
```

The os_signpost track lists each interval with its duration and metadata; the
Time Profiler track under it shows what the main thread ran during one (select
the interval, then read the call tree for that range).

**Repeatable numbers**: `PERF=1 Tests/run-self-tests.sh` adds the perf
suite, which seeds a 500-item history (short texts, ten 200 KB texts, twenty
5K screenshots) in a scratch folder and prints the median and p95 of each
scenario (store load and save, opening and searching the panel, previews,
restores, launcher keystrokes) to `build/self-test/perf.log`. It fails only if
its setup does, never on a number. `PERF_RUNS` changes the 20 runs per
scenario, `PERF_BIG_TEXTS=480` makes the history nearly as large as the limits
allow, and `PERF_ONLY=<scenario>` runs one scenario so a profiler can be
attached (see `Tests/SelfTest/PerfTests.swift`). The panels appear on screen
while it runs; clicking elsewhere closes them, and those runs are left out.

## Install

```bash
./install.sh   # builds, replaces ~/Applications/Launcher.app and starts it
```

Run it again after pulling or changing the code. It quits whichever copy is
running first (an app saves its clipboard history as it quits; a plain
`./Launcher` binary is stopped with SIGTERM, which can lose the last few
seconds of copies), and leaves the installed app in place if the build or the
copy fails. The installed app keeps reading this
repo's `workflows.json`, so editing or pulling that file needs no reinstall,
but moving the repo does.

### Signing

macOS remembers privacy permissions (Accessibility, used by the clipboard
history to paste, and Calendar) per code signature. `build.sh` signs ad-hoc
unless it finds a certificate, and an ad-hoc signature changes with every
build, so each rebuild loses those permissions; Accessibility still looks on in
System Settings, but pasting stops working. A certificate of your own, made
once, keeps the signature the same across builds:

1. Keychain Access > Keychain Access menu > Certificate Assistant > **Create a
   Certificate…**
2. Name: `alfresco Local Signing`, Identity Type: Self Signed Root,
   Certificate Type: **Code Signing**, and tick **Let me override defaults**.
   Continue, set Validity Period to `3650` days (the default is one year),
   and accept the other defaults.
3. In the login keychain, double-click the new certificate > Trust > Code
   Signing: **Always Trust**.
4. `./install.sh`. The first build asks to let `codesign` use the key: choose
   **Always Allow**.

`build.sh` then says `signed with "alfresco Local Signing"` and picks it up by
itself from then on (`SIGN_IDENTITY` picks another certificate, `-` forces
ad-hoc). It uses only a valid certificate: once it expires, or if step 3 was
skipped, it signs ad-hoc and says why. Make a new one then (the signature
changes, so grant the permissions again as below). Grant the permissions one last time, since the earlier ones belong to
the ad-hoc signature: clear them with

```bash
tccutil reset Accessibility local.launcher
```

```bash
tccutil reset Calendar local.launcher
```

then pick an item in the clipboard history and type `/cal` to get both
prompts again. The certificate only works on this Mac; it is not for
sharing the app with others, which needs a paid Developer ID and notarization.

## Start automatically at login

Install the app (above), then choose **Launch at Login** in its menu bar menu
(macOS 13+). It is offered only for the copy in `/Applications` or
`~/Applications`, since a login item pointing at `build/` would break on the
next build. If you added the app to System Settings > General > Login Items by
hand before, remove that entry so it isn't started twice (the second copy would
quit at once anyway).

Without the menu bar icon (`Config.showMenuBarIcon = false`), add
`~/Applications/Launcher.app` in System Settings > General > Login Items >
**Open at Login** > `+` instead.

<details>
<summary>Alternative: a LaunchAgent (works with the plain binary)</summary>

Run this from the repo folder: `$PWD` in the plist points the agent at this
repo's `workflows.json`. Don't combine it with Launch at Login or
`install.sh`, which refuses to run while the agent is loaded.

```bash
mkdir -p ~/Applications ~/Library/LaunchAgents
swiftc -O -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos12.0" $(find Sources -name '*.swift') -o ~/Applications/Launcher

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

</details>

macOS 13+ shows a one-time "Background Items Added" notification either way.
