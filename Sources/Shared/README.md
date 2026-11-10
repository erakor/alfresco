# Shared

Code used by more than one feature, plus the usage stats that every feature
reports to.

## Usage stats

alfresco counts how it is used, so you can see which keywords earn their
place and what is missing. Everything stays on your Mac, in
`~/Library/Application Support/Launcher/usage.json` (readable only by your
user), one bucket per calendar day, keeping the last 90 days (today
included). The menu bar's **Usage…** shows the last 30 days and can reveal the
file; [`/stats`](../Stats/README.md) in the launcher shows the last 7 days
and the commands nobody runs. If it was written by a newer build of alfresco, it is left as it is and
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
  how often the fallback is used, how often a command card is clicked
  (not which one: that counts when it runs), and how often the weather above
  the input is clicked. The launcher list uses the app and keyword
  counts to put what you use most first. What you typed to open an app is
  not part of these stats: it has its own file and switch
  ([Learned app picks](../Launcher/README.md#learned-app-picks)).
- The first word of multi-word fallback inputs, lowercased, only when it is a
  workflow keyword or a typo away from one (one letter added, missing, changed
  or swapped for a keyword of 4 letters, two for 5 letters or more; keywords
  of 1 to 3 letters must match exactly): `jira abc-42` (typed without the
  `/`) keeps `jira`, `jria abc-42` keeps `jria`, a mistyped `jira`, and so
  does Enter on the unknown command `/jria abc-42` (counted as an unknown
  command), while `divorce lawyer` or `pa taxes` keep nothing. Any
  other word, and the rest of the input, is never kept.
- Previews, weather and transit: answers received and failures, by kind of
  error.
- Calendar and transit: how often the event list and the departure board
  are shown, never what they list.
- Built-ins: how often each one's answer is copied (calculations,
  conversions, times, UUIDs, timestamps, dates, weeks), never what was typed
  or copied.
- Clipboard: copies by kind, copies and restores per app (by bundle ID), and
  skipped copies by reason. Never any content or file path.
- Pomodoro: focus sessions that ran their full length (not skipped ones), on
  the day they ended.

### Settings

In `Sources/App/Config.swift` (rebuild after a change):

- `usageTracking = false` turns it off (and hides **Usage…**).
- `usageTrackFallbackWords = false` keeps the counts but drops the fallback words.
- `usageRetentionDays` (90): how many days of buckets are kept, today included.
- `usageReportDays` (7): the days [`/stats`](../Stats/README.md) adds up.

## Code

- `UsageStats.swift`: the usage counters above.
- `StoreFile.swift`: reading and saving a versioned, owner-only JSON data
  file (usage.json and the launcher's typed-picks.json), and the day keys
  both use.
- `InternalURL.swift`: reads the feature (host) and action (path) of the
  `alfresco://` URLs workflows point at, for the pomodoro and system commands.
- `DigitShortcuts.swift`: the `⌘1` to `⌘9` key codes both panels use.
- `SetAsideFile.swift`: moves an unreadable clipboard history, usage or
  typed-picks file out of the way (`*.unreadable.json`, `-2`, `-3`…) instead of overwriting it.
- `HTTPSession.swift`: the URL session for weather, transit and preview requests (no
  cache, no cookies; redirects only to https, and a request carrying the
  transit token only on its own origin). At launch it also empties the cache
  earlier builds used, which could hold the WeatherAPI key.
- `ShortcutModifiers.swift`: `NSEvent.shortcutModifiers`, so ⌘ shortcuts
  work with Caps Lock on.
- `HotKeys.swift`: global hotkeys through Carbon `RegisterEventHotKey`, so
  neither hotkey needs the Accessibility or Input Monitoring permission.
- `FloatingPanel.swift`: the frosted, non-activating panel that both the
  [launcher](../Launcher/README.md) and the
  [clipboard history](../Clipboard/README.md) are built on (positioning on the
  screen under the mouse, fade in/out, dismissal on Esc, click-away or hotkey).
- `StatusRow.swift`: the loading / error line (spinner or icon, then text)
  that the [weather](../Weather/README.md) and
  [calendar](../Calendar/README.md) areas show under the input.
- `StripButton.swift`: `StripView`, the base of each line in the strip
  above the launcher input, and its clickable `StripButton`: the [weather](../Weather/README.md) on the right and
  the [next meeting](../Calendar/README.md) on the left (hover highlight,
  clicked on mouse up, never takes focus from the input).
- `AreaLabel.swift`: the text label style of the
  [calendar](../Calendar/README.md) and [pomodoro](../Pomodoro/README.md)
  areas under the input.
- `DateReading.swift`: reads typed dates (`25/12`, `2026-12-25`, `25 dec`,
  `demain`, `friday`) for the [built-ins](../BuiltIns/README.md) (`days`,
  `week`, `= today + 30 days`) and the [calendar](../Calendar/README.md)
  (`/cal demain`), plus `BuiltInContext` (the clock, time zone and locale,
  pinned by the self-test).
- `KeywordInput.swift`: reads input as `<keyword> [argument]`, bare for the
  built-ins (`time tokyo`) and after the `/` for the features that own a
  workflow keyword (`/weather paris`).
