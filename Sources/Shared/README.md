# Shared

Code used by more than one feature, plus the usage stats that every feature
reports to.

## Usage stats

alfresco counts how it is used, so you can see which keywords earn their
place and what is missing. Everything stays on your Mac, in
`~/Library/Application Support/Launcher/usage.json` (readable only by your
user), one bucket per calendar day, keeping the last 90 days (today
included). The menu bar's **Usage…** shows the last 30 days and can reveal the
file. If it was written by a newer build of alfresco, it is left as it is and
nothing is saved until the next launch, so that build keeps its counts. If it
can't be read, it is moved aside as `usage.unreadable.json` (then
`usage.unreadable-2.json` and so on, never replacing an earlier one, up to 100)
and counting starts over; with all 100 taken, the file is left alone and
nothing is saved until the next launch.

Recorded:

- Launcher: how often it opens, how often it closes without opening anything
  (and whether something was typed), Enter on a keyword still missing its
  argument, each workflow run (by its first keyword: `pr` or `pr …`, never what
  you typed after it), which installed apps were opened (by bundle ID), and
  how often the fallback is used. The launcher list uses the app and keyword
  counts to put what you use most first.
- The first word of multi-word fallback inputs, lowercased, if it looks like a
  keyword (letters, digits, `-`, `_`, up to 20 characters): `jria abc-42` keeps
  `jria`, a mistyped `jira`. The rest of the input is never kept.
- Previews and weather: answers received and failures, by kind of error.
- Clipboard: copies by kind, copies and restores per app (by bundle ID), and
  skipped copies by reason. Never any content or file path.

### Settings

In `Sources/App/Config.swift` (rebuild after a change):

- `usageTracking = false` turns it off (and hides **Usage…**).
- `usageTrackFallbackWords = false` keeps the counts but drops the fallback words.
- `usageRetentionDays` (90): how many days of buckets are kept, today included.

## Code

- `UsageStats.swift`: the usage counters above.
- `DigitShortcuts.swift`: the `⌘1` to `⌘9` key codes both panels use.
- `SetAsideFile.swift`: moves an unreadable clipboard history or usage file
  out of the way (`*.unreadable.json`, `-2`, `-3`…) instead of overwriting it.
- `HotKeys.swift`: global hotkeys through Carbon `RegisterEventHotKey`, so
  neither hotkey needs the Accessibility or Input Monitoring permission.
- `FloatingPanel.swift`: the frosted, non-activating panel that both the
  [launcher](../Launcher/README.md) and the
  [clipboard history](../Clipboard/README.md) are built on (positioning on the
  screen under the mouse, fade in/out, dismissal on Esc, click-away or hotkey).
