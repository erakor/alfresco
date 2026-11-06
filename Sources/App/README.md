# App

The wiring that ties the features together.

- Runs as an accessory app: no Dock icon, and an optional menu bar icon with
  Open Launcher, Clipboard History, Clear Clipboard History, Start Pomodoro,
  the Workflows submenu, Edit Workflows, Show Workflows in Finder, Usage,
  Forget Learned App Picks, Launch at Login and Quit. The menu bar icon (`MenuBarIcon.swift`) is a
  line drawing of the app icon, the sun behind the search bar, drawn in
  code as a template image so it follows light and dark menu bars.
- Launch at Login (macOS 13+, `LoginItem.swift`) registers the running app
  with `SMAppService`. It can be turned on only in a copy installed directly
  in `/Applications` or `~/Applications` (by `install.sh`, see the
  [root README](../../README.md#install)), since a login item pointing at
  `build/` breaks on the next build. It shows a dash while macOS waits for
  approval, or after it was turned off in System Settings > General > Login
  Items; clicking it then opens that page.
- Registers both hotkeys: the [launcher](../Launcher/README.md) and the
  [clipboard history](../Clipboard/README.md).
- Runs the `alfresco://` URLs that workflows point at (today
  `alfresco://pomodoro/...`, see [Pomodoro](../Pomodoro/README.md), and
  `alfresco://system/...`, see [System](../System/README.md)).
- Only one copy runs at a time: a second one (plain binary, `build/`, or the
  installed app) exits at once instead of fighting over the hotkeys and the
  clipboard history.

## Settings

Every compile-time setting lives in the `Config` enum in `Config.swift`; edit
it and rebuild. Each feature's README lists its own settings. The ones that
belong to the app itself:

- `showMenuBarIcon`: set to `false` for a fully invisible agent. The
  [pomodoro](../Pomodoro/README.md) countdown still shows while a session runs.

## Code

- `Launcher.swift`: the entry point (`LauncherApp`: `--lock-path`, which
  prints the lock file `install.sh` looks for, `--check`, which checks a
  workflows file and exits, then the single-instance lock) and
  `AppDelegate` (hotkeys, menu bar, `alfresco://` routing).
- `Config.swift`: settings, and where the workflows file is found.
- `LoginItem.swift`: the Launch at Login menu item.
- `Alerts.swift`: `NSAlert.runModalInFront`, which brings the accessory app
  forward before an alert.
