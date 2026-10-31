---
name: run-app
description: Build alfresco and relaunch it so a change can be tried for real. Use when asked to run, launch, restart, or try the app, or to check a change to hotkeys, panels, the clipboard history, or the menu bar.
---

# Run alfresco

Only one copy can own the global hotkeys: Carbon's `RegisterEventHotKey`
refuses a combination another process already registered. So quit any running
copy before launching the new build, or its hotkeys will silently do nothing.

1. **Build.** `./build.sh` from the repo root. Stop and report the compiler
   output if it fails. Nothing else verifies the code, so a clean build is the
   first check.

2. **See what's running.** `pgrep -fl 'MacOS/Launcher$'`. It is often the
   user's installed copy at `~/Applications/Launcher.app` (a Login Item), not
   `build/`.
   - If `launchctl list | grep -w local.launcher` shows a LaunchAgent, killing
     the process makes `KeepAlive` respawn the *old* binary. Ask the user
     whether to `launchctl bootout gui/$(id -u)/local.launcher` for the session,
     and remind them to `launchctl bootstrap` it again afterwards.

3. **Quit it.** `osascript -e 'quit app id "local.launcher"'`, then
   `pkill -x Launcher` if it is still running a second later. Both copies share
   that bundle id. Quitting is harmless: the clipboard history is saved to disk.

4. **Launch the build.** `open build/Launcher.app`, then confirm with `pgrep`
   that it stays up after a couple of seconds. If it exits at once, an older
   copy is probably still running: the app holds a lock and a second copy quits
   with "Launcher is already running". Otherwise run
   `build/Launcher.app/Contents/MacOS/Launcher` in the foreground to see the
   `NSLog` output, or read
   `log show --last 1m --predicate 'process == "Launcher"'`.

5. **Hand over.** You can't press the hotkeys yourself, and the app needs no
   Accessibility permission for that, so don't ask for it. Tell the user what to
   try: ⌘⇧Space for the launcher and ⌘⌥C for the clipboard history (or whatever
   `Config.hotKey` / `Config.clipboardHotKey` now say), plus the specific
   behavior that changed.

6. **Afterwards.** The installed `~/Applications/Launcher.app` is still the old
   version and isn't running. Offer to update it
   (`rm -rf ~/Applications/Launcher.app && cp -R build/Launcher.app ~/Applications/ && open ~/Applications/Launcher.app`)
   or to reopen it unchanged. Don't overwrite it without asking.

To test against a scratch workflows file without touching the repo's, launch the
binary with `ALFRESCO_WORKFLOWS=/path/to/file.json build/Launcher.app/Contents/MacOS/Launcher`.
Changes to `workflows.json` alone need no rebuild or relaunch (see the
`add-workflow` skill).
