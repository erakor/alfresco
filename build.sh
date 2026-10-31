#!/usr/bin/env bash
# Compiles Launcher.swift and wraps it in a minimal, ad-hoc signed .app bundle
# (LSUIElement, so it never shows a Dock icon) at build/Launcher.app. The app
# reads workflows from this repo's workflows.json.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/Launcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library Launcher.swift -o "$APP/Contents/MacOS/Launcher"

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
