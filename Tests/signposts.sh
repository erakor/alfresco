#!/usr/bin/env bash
# Prints alfresco's performance intervals live, one line per interval as it
# ends: its duration, name and metadata (counts, sizes and kinds only; see
# Sources/Shared/Signposts.swift). Ctrl-C to stop. Needs no Xcode.
#
#   Tests/signposts.sh                     # the app (local.launcher)
#   Tests/signposts.sh SUBSYSTEM           # e.g. local.launcher.selftest
#   SIGNPOSTS_MIN_MS=5 Tests/signposts.sh  # only intervals of 5 ms or more
#                                          # (and no point events)
#
# Uses /usr/bin/log by its full path: zsh has a `log` builtin of its own.
set -euo pipefail
SUBSYSTEM="${1:-local.launcher}"
# Checked, since it goes into the log predicate.
if ! [[ "$SUBSYSTEM" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "signposts.sh: not a subsystem name: $SUBSYSTEM" >&2
  exit 2
fi
export SIGNPOSTS_MIN_MS="${SIGNPOSTS_MIN_MS:-0}"

/usr/bin/log stream --signpost --style ndjson \
  --predicate "subsystem == \"$SUBSYSTEM\" AND category == \"performance\"" |
  python3 -I -u -c '
import json, os, sys
from datetime import datetime

minimum = float(os.environ["SIGNPOSTS_MIN_MS"])
began = {}

def when(entry):
    # "2026-11-02 09:33:55.927446-0500": microseconds and the UTC offset,
    # so an interval across a daylight saving change still measures right.
    return datetime.strptime(entry["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z")

for line in sys.stdin:
    try:
        entry = json.loads(line)
    except ValueError:
        continue  # the "Filtering the log data..." banner
    kind = entry.get("signpostType")
    name = entry.get("signpostName", "")
    message = entry.get("eventMessage") or ""
    key = (entry.get("processID"), entry.get("signpostID"), name)
    if kind == "begin":
        began[key] = entry
    elif kind == "end" and key in began:
        start = began.pop(key)
        ms = (when(entry) - when(start)).total_seconds() * 1000
        if ms >= minimum:
            print("%9.2f ms  %-24s %s" % (ms, name, message or start.get("eventMessage") or ""))
    elif kind == "event" and minimum <= 0:
        # Point events (thumbnail.hit fires on every row drawn) have no
        # duration: shown only when every interval is.
        print("%12s  %-24s %s" % ("", name, message))
'
