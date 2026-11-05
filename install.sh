#!/usr/bin/env bash
# Builds the app and installs it as ~/Applications/Launcher.app, replacing the
# installed copy, then starts it. Run it again after pulling or changing the
# code. The installed app still reads this repo's workflows.json, so edits to
# that file need no reinstall.
#
# Environment (optional), all passed on to build.sh:
#   BUILD_DIR     where build.sh puts Launcher.app (default: build in the repo)
#   BUNDLE_ID     CFBundleIdentifier (default: local.launcher)
#   SIGN_IDENTITY the code signing identity
set -euo pipefail

# Relative paths are the caller's, so they are made absolute before the cd.
absolute() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
[ -n "${BUILD_DIR:-}" ] && BUILD_DIR="$(absolute "$BUILD_DIR")"

cd "$(dirname "$0")"

# ~/Applications is one of the two folders where Launch at Login can be
# turned on (LoginItem.isInstalledLocation).
INSTALL_DIR="$HOME/Applications"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
BUNDLE_ID="${BUNDLE_ID:-local.launcher}"
APP="$INSTALL_DIR/Launcher.app"
STAGED="$INSTALL_DIR/.Launcher.app.installing"

# A LaunchAgent with KeepAlive would restart the old copy as soon as it quits.
# Checked before building, so it fails fast.
if launchctl print "gui/$(id -u)/$BUNDLE_ID" > /dev/null 2>&1; then
    echo "install.sh: the $BUNDLE_ID LaunchAgent is loaded. Remove it first (README.md, \"Start automatically at login\"):" >&2
    echo "  launchctl bootout gui/$(id -u)/$BUNDLE_ID && rm ~/Library/LaunchAgents/$BUNDLE_ID.plist" >&2
    exit 1
fi

BUILD_DIR="$BUILD_DIR" BUNDLE_ID="$BUNDLE_ID" ./build.sh

# Every running copy (installed, build/, a plain binary) holds this file open
# with a lock until it exits, so its holders are exactly the copies the new one
# would collide with. The app itself says where it is.
LOCK="$("$BUILD_DIR/Launcher.app/Contents/MacOS/Launcher" --lock-path)"
lock_holders() { [ -e "$LOCK" ] && lsof -t -- "$LOCK" 2>/dev/null || true; }
no_holders() { [ -z "$(lock_holders)" ]; }
has_holders() { [ -n "$(lock_holders)" ]; }
# Runs a check every 0.5 s for 5 s, until it passes.
wait_until() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        "$@" && return 0
        sleep 0.5
    done
    "$@"
}

# Copied next to the old app first, so a failure here leaves it in place.
mkdir -p "$INSTALL_DIR"
rm -rf "$STAGED"
ditto "$BUILD_DIR/Launcher.app" "$STAGED"

# Only one copy can hold the hotkeys. An app quits through its Quit command,
# which saves the clipboard history; a plain binary only answers SIGTERM,
# which skips that save (at most the last few seconds of copies).
if has_holders; then
    osascript -e "quit app id \"$BUNDLE_ID\"" > /dev/null 2>&1 || true
    if ! wait_until no_holders; then
        # shellcheck disable=SC2046 # one PID per line
        kill -TERM $(lock_holders) 2>/dev/null || true
        if ! wait_until no_holders; then
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
if ! wait_until has_holders; then
    echo "install.sh: installed $APP, but it isn't running; see Console.app or run $APP/Contents/MacOS/Launcher" >&2
    exit 1
fi
echo "Installed and started $APP"
