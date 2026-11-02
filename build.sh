#!/usr/bin/env bash
# Compiles the Swift sources under Sources/ and wraps them in a minimal, ad-hoc signed .app
# bundle (LSUIElement, so it never shows a Dock icon) at build/Launcher.app.
# The app reads workflows from this repo's workflows.json.
#
# Environment (all optional, used by Tests/run-self-tests.sh):
#   BUILD_DIR     where Launcher.app goes (default: build)
#   SOURCE_DIRS   folders whose .swift files are compiled (default: Sources)
#   SWIFTC_FLAGS  extra swiftc flags, e.g. "-D SELFTEST"
set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR="${BUILD_DIR:-build}"
SOURCE_DIRS="${SOURCE_DIRS:-Sources}"
APP="$BUILD_DIR/Launcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# shellcheck disable=SC2086 # word splitting is intended
swiftc -O -parse-as-library -swift-version 6 ${SWIFTC_FLAGS:-} $(find $SOURCE_DIRS -name '*.swift') \
    -o "$APP/Contents/MacOS/Launcher"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Launcher</string>
    <key>CFBundleIdentifier</key>
    <string>local.launcher</string>
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

# Point the app at this repo's workflows.json, so edits to it apply without
# rebuilding. Rebuild if you move the repo.
/usr/libexec/PlistBuddy -c "Add :AlfrescoWorkflowsFile string $PWD/workflows.json" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "Built $APP"
