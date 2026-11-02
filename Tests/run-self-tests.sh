#!/usr/bin/env bash
# Builds the self-test variant of the app (-D SELFTEST, with Tests/ compiled
# in) and runs it for real on this Mac:
#
#   1. the unit suite as a plain binary (no bundle, so no notifications)
#   2. the unit suite inside an .app bundle
#   3. a relaunch: one process saves a paused session, a second reads it back
#   4. a running session held in the menu bar, with a screenshot
#
# Every run uses a fresh scratch folder as ALFRESCO_SUPPORT_DIR, so the real
# clipboard history and pomodoro state are never touched, and is killed
# after 60 s. Results go to $OUT_DIR (default build/self-test): self-test.log
# and menubar.png. Exits non-zero if any check failed.
#
# Needs no running copy of the app to be quit: the self-test skips the
# single-instance lock and registers no hotkeys.
set -uo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${OUT_DIR:-build/self-test}"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
LOG="$OUT_DIR/self-test.log"
: > "$LOG"
status=0

say() { echo "$*" | tee -a "$LOG"; }

# Runs a command with a time limit (macOS has no `timeout`), logging its output.
run() {
  local name="$1"; shift
  say ""
  say "== $name"
  perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 60 "$@" 2>&1 | tee -a "$LOG"
  local code="${PIPESTATUS[0]}"
  if [ "$code" -ne 0 ]; then
    say "FAIL $name: exit status $code"
    status=1
  fi
}

scratch() { mktemp -d "${TMPDIR:-/tmp}/alfresco-selftest.XXXXXX"; }

set -e
BIN="$OUT_DIR/Launcher"
swiftc -O -parse-as-library -swift-version 6 -D SELFTEST $(find Sources Tests -name '*.swift') -o "$BIN"
BUILD_DIR="$OUT_DIR/bundle" SOURCE_DIRS="Sources Tests" SWIFTC_FLAGS="-D SELFTEST" ./build.sh > /dev/null
APP_BIN="$OUT_DIR/bundle/Launcher.app/Contents/MacOS/Launcher"
set +e

run "unit, plain binary" env ALFRESCO_SUPPORT_DIR="$(scratch)" "$BIN" --self-test unit
run "unit, app bundle" env ALFRESCO_SUPPORT_DIR="$(scratch)" "$APP_BIN" --self-test unit

relaunch="$(scratch)"
run "relaunch, first process" env ALFRESCO_SUPPORT_DIR="$relaunch" "$APP_BIN" --self-test relaunch-write
run "relaunch, second process" env ALFRESCO_SUPPORT_DIR="$relaunch" "$APP_BIN" --self-test relaunch-read

# Menu bar screenshot: hold a running session, wait for it to be up, capture.
say ""
say "== menu bar screenshot"
hold_log="$OUT_DIR/menubar-hold.log"
env ALFRESCO_SUPPORT_DIR="$(scratch)" SELFTEST_HOLD_SECONDS=10 \
  perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 60 "$APP_BIN" --self-test menubar-hold > "$hold_log" 2>&1 &
hold_pid=$!
for _ in $(seq 1 50); do
  grep -q '^HOLDING' "$hold_log" && break
  sleep 0.2
done
sleep 2
if screencapture -x "$OUT_DIR/menubar.png" 2>>"$LOG"; then
  say "Saved $OUT_DIR/menubar.png"
else
  say "(screencapture failed; no screenshot)"
fi
wait "$hold_pid"
hold_code=$?
tee -a "$LOG" < "$hold_log"
if [ "$hold_code" -ne 0 ]; then
  say "FAIL menu bar hold: exit status $hold_code"
  status=1
fi

passed=$(grep -c '^PASS ' "$LOG")
failed=$(grep -c '^FAIL ' "$LOG")
say ""
say "Total: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || status=1

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    if [ "$status" -eq 0 ]; then echo "## Self-test: all $passed checks passed"; else echo "## Self-test: $failed failed, $passed passed"; fi
    echo
    echo "Runs on $(sw_vers -productName) $(sw_vers -productVersion). Log and menu bar screenshot are in the run's artifacts."
    echo
    echo '```'
    grep -E '^(== |PASS |FAIL |Self-test )' "$LOG"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit "$status"
