#!/usr/bin/env bash
# Builds the app and installs it as ~/Applications/Launcher.app, replacing the
# installed copy, then starts it. Run it again after pulling or changing the
# code. The installed app still reads this repo's workflows.json, so edits to
# that file need no reinstall.
#
# Environment (optional):
#   INSTALL_DIR   where Launcher.app goes (default: ~/Applications)
#   SIGN_IDENTITY passed on to build.sh
set -euo pipefail

cd "$(dirname "$0")"

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
BUNDLE_ID="local.launcher"

./build.sh

# A LaunchAgent with KeepAlive would restart the old copy as soon as it quits.
if launchctl print "gui/$(id -u)/$BUNDLE_ID" > /dev/null 2>&1; then
    echo "install.sh: the $BUNDLE_ID LaunchAgent is loaded. Remove it first (README.md, \"Start automatically at login\"):" >&2
    echo "  launchctl bootout gui/$(id -u)/$BUNDLE_ID && rm ~/Library/LaunchAgents/$BUNDLE_ID.plist" >&2
    exit 1
fi

# Only one copy can hold the hotkeys, so whichever copy runs (installed,
# build/, or a plain binary) is asked to quit. Quitting saves the clipboard
# history first.
if pgrep -f 'MacOS/Launcher$' > /dev/null; then
    osascript -e "quit app id \"$BUNDLE_ID\"" > /dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f 'MacOS/Launcher$' > /dev/null || break
        sleep 0.5
    done
    if pgrep -f 'MacOS/Launcher$' > /dev/null; then
        echo "install.sh: Launcher is still running; quit it from the menu bar and run install.sh again" >&2
        exit 1
    fi
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/Launcher.app"
ditto build/Launcher.app "$INSTALL_DIR/Launcher.app"
open "$INSTALL_DIR/Launcher.app"
echo "Installed and started $INSTALL_DIR/Launcher.app"
