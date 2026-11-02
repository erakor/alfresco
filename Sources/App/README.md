# App

The wiring that ties the features together.

- Runs as an accessory app: no Dock icon, and an optional menu bar icon with
  Open Launcher, Clipboard History, Clear Clipboard History, Start Pomodoro,
  the Workflows submenu, Edit Workflows, Show Workflows in Finder, Usage and
  Quit.
- Registers both hotkeys: the [launcher](../Launcher/README.md) and the
  [clipboard history](../Clipboard/README.md).
- Runs the `alfresco://` URLs that workflows point at (today
  `alfresco://pomodoro/...`, see [Pomodoro](../Pomodoro/README.md)).
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

- `Launcher.swift`: the entry point (`LauncherApp`, single-instance lock) and
  `AppDelegate` (hotkeys, menu bar, `alfresco://` routing).
- `Config.swift`: settings, and where the workflows file is found.
