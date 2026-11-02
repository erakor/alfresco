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
- Keyword suggestions as you type: `p` lists `pr`, `Tab` completes, `↑` `↓` choose.

| Input          | Opens                                                             |
| -------------- | ----------------------------------------------------------------- |
| `pr 123`       | `https://github.com/<owner>/<repo>/pull/123` (`pr #123` works too) |
| `jira abc-42`  | `https://understood.atlassian.net/browse/ABC-42`                  |
| `cf 5KsDBWseXY` | `https://app.contentful.com/spaces/p0qf7j048i0q/entries/5KsDBWseXY` |
| `weather`      | `https://wttr.in/?lang=fr&m` (where you are, in French, metric); the hint shows the current weather |
| `weather paris` | `https://wttr.in/paris?lang=fr&m`                                |
| `saf`, `code`, `vsc` | The installed app whose name matches (Safari, Visual Studio Code) |
| `pomo`         | Starts a 25 min [pomodoro](Sources/Pomodoro/README.md), or pauses / resumes it (nothing opens) |
| anything else  | `https://www.google.com/search?q=...`                             |

## Features

Each feature has its own README, next to its code in `Sources/`:

| Feature | What it does |
| ------- | ------------ |
| [Launcher](Sources/Launcher/README.md) | The `⌘⇧Space` bar: workflows (`workflows.json`, its format and where it is read from), keyword suggestions, and opening apps by name. |
| [Weather](Sources/Weather/README.md) | The forecast under the input for `weather` / `weather <place>`, and the current weather above it. Needs a free WeatherAPI.com key. |
| [Pomodoro](Sources/Pomodoro/README.md) | A focus / break timer started with `pomo`, counting down in the menu bar. |
| [Clipboard history](Sources/Clipboard/README.md) | 24 hours of copied text, images and files on `⌘⌥C`, pasted back into the app you were using. |
| [Shared](Sources/Shared/README.md) | Local usage stats (menu bar **Usage…**), plus the hotkeys and the panel the features share. |
| [App](Sources/App/README.md) | The wiring: menu bar, hotkey registration, `alfresco://` URLs, single instance, and `Config`. |

## Configure

Settings are compile-time: edit the `Config` enum in `Sources/App/Config.swift`,
then rebuild. Each feature's README lists the settings it uses; the most common
ones are:

- `hotKey`: `.commandShiftSpace` (default) or `.optionSpace` (macOS 14 and
  earlier only). See [Launcher](Sources/Launcher/README.md#settings).
- `clipboardHotKey`: `⌘⌥C` by default. See
  [Clipboard history](Sources/Clipboard/README.md#settings).
- `showMenuBarIcon`: set to `false` for a fully invisible agent.

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
