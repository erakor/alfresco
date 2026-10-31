# alfresco

A single-file, Spotlight-style URL launcher for macOS. Press a global hotkey,
type a command, hit Enter, and the URL opens in your default browser.

- Hotkey via Carbon `RegisterEventHotKey`: **no Accessibility or Screen Recording permission**.
- Accessory agent: no Dock icon (optional menu bar icon with Open / Edit Workflows / Quit).
- Workflows live in a JSON file and reload automatically: no rebuild to add one.
- Frosted `NSVisualEffectView` panel, auto-focused input, fade/slide animation.
- `Esc`, clicking outside, or pressing the hotkey again dismisses it.
- `⌘X/C/V/A/Z` work in the input even though the app has no menu bar.

| Input          | Opens                                                             |
| -------------- | ----------------------------------------------------------------- |
| `pr 123`       | `https://github.com/<owner>/<repo>/pull/123` (`pr #123` works too) |
| `jira abc-42`  | `https://understood.atlassian.net/browse/ABC-42`                  |
| `cf 5KsDBWseXY` | `https://app.contentful.com/spaces/p0qf7j048i0q/entries/5KsDBWseXY` |
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
| `keywords`   | One or more single words, matched case-insensitively. First match wins.     |
| `title`      | Shown in the hint as you type.                                              |
| `url`        | `{query}` is replaced with the percent-encoded argument. Without `{query}`, typing the keyword alone opens the URL. |
| `transforms` | Optional, applied in order to the argument: `uppercase`, `lowercase`, `trim`, `stripPrefix:<text>`, `stripSuffix:<text>`. |
| `fallback`   | Optional. Used when nothing matches; its `url` must contain `{query}`.      |

If the file has a mistake or is missing, the launcher keeps using the last good
version and shows the error in the hint area (hover it for the full message).

## Configure

Edit the `Config` enum at the top of `Launcher.swift`, then rebuild:

- `hotKey`: `.commandShiftSpace` (default) or `.optionSpace`. macOS 15+ rejects
  Option-only hotkeys, so `.optionSpace` only works on macOS 14 and earlier.
- `showMenuBarIcon`: set to `false` for a fully invisible agent.
- `workflowsSource`: how the workflows file is found (see above).

## Build

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
# Plain binary
swiftc -O -parse-as-library Launcher.swift -o Launcher
./Launcher

# Or an .app bundle (recommended for Login Items)
./build.sh            # -> build/Launcher.app
```

`-parse-as-library` is required because the file uses `@main`.

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
swiftc -O -parse-as-library Launcher.swift -o ~/Applications/Launcher

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
