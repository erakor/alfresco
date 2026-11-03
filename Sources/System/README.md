# System

Type one of these in the [launcher](../Launcher/README.md) and press Enter:

| Input          | Does                                   |
| -------------- | -------------------------------------- |
| `sleep`        | Puts the Mac to sleep                  |
| `lock`         | Locks the screen, like `⌃⌘Q`           |
| `displaysleep` | Turns the display off                  |

- None of them asks for a permission, in the plain `./Launcher` binary or in
  `build/Launcher.app`.
- `sleep` and `displaysleep` wait half a second, so the launcher has closed
  and letting go of Enter doesn't wake the Mac straight back up.
- `lock` does what the Apple menu's Lock Screen does. Whether `displaysleep`
  also locks depends on System Settings > Lock Screen > "Require password
  after screen saver begins or display is turned off".
- If a command can't run (say `pmset` fails), you hear a beep.
- The keywords are ordinary workflows in [`workflows.json`](../../workflows.json)
  pointing at `alfresco://system/sleep`, `alfresco://system/lock` and
  `alfresco://system/displaysleep`. Rename them or add others (say `zz` →
  `alfresco://system/sleep`) there. An action it doesn't know beeps.

## Code

- `SystemCommand.swift`: parses `alfresco://system/...` URLs and runs them:
  `pmset sleepnow` / `pmset displaysleepnow` for sleep and display sleep, and
  `SACLockScreenImmediate` from the private `login` framework (what the
  system's Lock Screen menu item calls) for lock. If a future macOS drops that
  function, or it fails, `lock` beeps instead.
- `InternalURL` (in [Shared](../Shared/README.md)) reads the feature and
  action out of `alfresco://` URLs, for this and the pomodoro.
