#!/usr/bin/env bash
# Builds the app and installs it as ~/Applications/Launcher.app, replacing the
# installed copy, then starts it. Run it again after pulling or changing the
# code. The installed app still reads this repo's workflows.json, so edits to
# that file need no reinstall.
#
# Environment (optional):
#   INSTALL_DIR   ~/Applications (default) or /Applications: the only two
#                 folders where Launch at Login can be turned on
#   BUILD_DIR     passed on to build.sh (default: build in the repo)
#   SIGN_IDENTITY passed on to build.sh
set -euo pipefail

# Relative paths are the caller's, so they are made absolute before the cd.
absolute() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
INSTALL_DIR="$(absolute "${INSTALL_DIR:-$HOME/Applications}")"
INSTALL_DIR="${INSTALL_DIR%/}"
[ -n "${BUILD_DIR:-}" ] && BUILD_DIR="$(absolute "$BUILD_DIR")"

cd "$(dirname "$0")"

if [ "$INSTALL_DIR" != "$HOME/Applications" ] && [ "$INSTALL_DIR" != "/Applications" ]; then
    echo "install.sh: INSTALL_DIR must be ~/Applications or /Applications, where Launch at Login works (got $INSTALL_DIR)" >&2
    exit 2
fi

BUNDLE_ID="local.launcher"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
APP="$INSTALL_DIR/Launcher.app"
STAGED="$INSTALL_DIR/.Launcher.app.installing"
# Every running copy (installed, build/, a plain binary) holds this file
# open with a lock until it exits, so its holders are exactly the copies the
# new one would collide with. The self-test never takes it.
LOCK="$HOME/Library/Application Support/Launcher/launcher.lock"

lock_holders() {
    [ -e "$LOCK" ] || return 0
    lsof -t -- "$LOCK" 2>/dev/null || true
}

# Waits up to 5 s for no copy to hold the lock.
wait_for_quit() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -z "$(lock_holders)" ] && return 0
        sleep 0.5
    done
    [ -z "$(lock_holders)" ]
}

# A LaunchAgent with KeepAlive would restart the old copy as soon as it quits.
# Checked before building, so it fails fast.
if launchctl print "gui/$(id -u)/$BUNDLE_ID" > /dev/null 2>&1; then
    echo "install.sh: the $BUNDLE_ID LaunchAgent is loaded. Remove it first (README.md, \"Start automatically at login\"):" >&2
    echo "  launchctl bootout gui/$(id -u)/$BUNDLE_ID && rm ~/Library/LaunchAgents/$BUNDLE_ID.plist" >&2
    exit 1
fi

BUILD_DIR="$BUILD_DIR" ./build.sh

# Copied next to the old app first, so a failure here leaves it in place.
mkdir -p "$INSTALL_DIR"
rm -rf "$STAGED"
ditto "$BUILD_DIR/Launcher.app" "$STAGED"

# Only one copy can hold the hotkeys. An app quits through its Quit command,
# which saves the clipboard history; a plain binary only answers SIGTERM,
# which skips that save (at most the last few seconds of copies).
if [ -n "$(lock_holders)" ]; then
    osascript -e "quit app id \"$BUNDLE_ID\"" > /dev/null 2>&1 || true
    if ! wait_for_quit; then
        # shellcheck disable=SC2046 # one PID per line
        kill -TERM $(lock_holders) 2>/dev/null || true
        if ! wait_for_quit; then
            rm -rf "$STAGED"
            echo "install.sh: Launcher (PID $(lock_holders | tr '\n' ' ')) is still running; quit it and run install.sh again" >&2
            exit 1
        fi
    fi
fi

rm -rf "$APP"
mv "$STAGED" "$APP"
open "$APP"

# The new copy takes the lock within a moment of starting; if it doesn't, it
# exited (another copy appeared, or it crashed).
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$(lock_holders)" ] && break
    sleep 0.5
done
if [ -z "$(lock_holders)" ]; then
    echo "install.sh: installed $APP, but it isn't running; see Console.app or run $APP/Contents/MacOS/Launcher" >&2
    exit 1
fi
echo "Installed and started $APP"
