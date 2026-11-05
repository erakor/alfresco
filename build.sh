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
#   SIGN_IDENTITY the code signing identity (default: "alfresco Local Signing"
#                 when that certificate is in the keychain, else ad-hoc). "-"
#                 forces ad-hoc.
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
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Typing "/cal" in the launcher lists your upcoming events.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Typing "/cal" in the launcher lists your upcoming events.</string>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"

# Point the app at this repo's workflows.json, so edits to it apply without
# rebuilding. Rebuild if you move the repo.
/usr/libexec/PlistBuddy -c "Add :AlfrescoWorkflowsFile string $PWD/workflows.json" "$APP/Contents/Info.plist"

# Signing. macOS keeps privacy permissions (Accessibility for the clipboard
# history's paste, Calendar) per signature. An ad-hoc signature changes with
# every build, so each rebuild silently loses them. A certificate of your own
# keeps the same signature across builds (README.md, "Signing").
DEFAULT_IDENTITY="alfresco Local Signing"
SIGN_LABEL="${SIGN_IDENTITY:-$DEFAULT_IDENTITY}"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    # Only valid identities (-v: not expired, trusted), by SHA-1, so an
    # expired copy or a second certificate of the same name never makes
    # codesign fail or refuse an ambiguous name. Lines read
    #   1) <SHA-1> "<name>"
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -v name="\"$DEFAULT_IDENTITY\"" 'index($0, name) { print $2; exit }' || true)"
    if [ -z "$SIGN_IDENTITY" ]; then
        SIGN_IDENTITY="-"
        [ -z "${CI:-}" ] && echo "build.sh: no valid \"$DEFAULT_IDENTITY\" certificate (missing, expired or not trusted), signing ad-hoc: permissions reset on each build; see README.md, Signing" >&2
    fi
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Built $APP (ad-hoc signed)"
else
    echo "Built $APP (signed with \"$SIGN_LABEL\")"
fi
