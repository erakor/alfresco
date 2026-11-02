#!/usr/bin/env bash
# Compiles the Swift sources under Sources/ and wraps them in a minimal, ad-hoc signed .app
# bundle (LSUIElement, so it never shows a Dock icon) at build/Launcher.app.
# The app reads workflows from this repo's workflows.json.
#
# Environment (all optional, used by Tests/run-self-tests.sh):
#   BUILD_DIR     where Launcher.app goes (default: build in the repo)
#   EXECUTABLE    an already built binary to bundle instead of compiling
#   BUNDLE_ID     CFBundleIdentifier (default: local.launcher). Give a test
#                 bundle its own, so LaunchServices and notification
#                 permission never mistake it for the real app.
set -euo pipefail

# Relative paths are the caller's, so they are made absolute before the cd.
absolute() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
[ -n "${BUILD_DIR:-}" ] && BUILD_DIR="$(absolute "$BUILD_DIR")"
[ -n "${EXECUTABLE:-}" ] && EXECUTABLE="$(absolute "$EXECUTABLE")"
if [ -n "${EXECUTABLE:-}" ] && [ ! -f "$EXECUTABLE" ]; then
    echo "build.sh: EXECUTABLE $EXECUTABLE not found" >&2
    exit 1
fi

cd "$(dirname "$0")"

BUILD_DIR="${BUILD_DIR:-build}"
BUNDLE_ID="${BUNDLE_ID:-local.launcher}"
APP="$BUILD_DIR/Launcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

if [ -n "${EXECUTABLE:-}" ]; then
    cp "$EXECUTABLE" "$APP/Contents/MacOS/Launcher"
else
    # The target sets the minimum macOS version; without it swiftc builds for
    # the running one, whatever LSMinimumSystemVersion says.
    swiftc -O -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos12.0" $(find Sources -name '*.swift') -o "$APP/Contents/MacOS/Launcher"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Launcher</string>
    <key>CFBundleIdentifier</key>
    <string>BUNDLE_ID_PLACEHOLDER</string>
    <key>CFBundleExecutable</key>
    <string>Launcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"

# Point the app at this repo's workflows.json, so edits to it apply without
# rebuilding. Rebuild if you move the repo.
/usr/libexec/PlistBuddy -c "Add :AlfrescoWorkflowsFile string $PWD/workflows.json" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "Built $APP"
