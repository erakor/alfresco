# Stats

Type `/stats` in the [launcher](../Launcher/README.md) to see how you used
alfresco over the last 7 days, under the input instead of the suggestion
list. It reads the local [usage stats](../Shared/README.md#usage-stats), so
nothing leaves your Mac.

- **Four figures**: commands run (each `/` workflow, with or without an
  argument), apps opened from the launcher, clipboard items put back
  (pasted or copied from the history), and pomodoro focus sessions that
  ran their full length.
- **Top commands** and **top apps**, five each, with a bar for each count.
  `/pr` and `/pr 12` count as one command. Each line has the icon of the
  app the command opens, or of the app itself.
- **Commands nobody runs**: the keywords in `workflows.json` that never ran
  in the 90 days the stats keep ("2 never run in 90 days: /cf,
  /displaysleep"). When counting started more recently, the line says since
  when, and so does the title ("Since 3 Nov") while that is within the week.
  Candidates to rename, or to delete.
- Enter opens the menu bar's **Usage…** summary of the last 30 days, which
  has every counter and a button that reveals `usage.json`. The hint says
  so: "↩ Last 30 days in detail".

The report is worked out once when it appears, from counts that are already
in memory. It isn't shown when `Config.usageTracking` is off; `/stats` then
beeps.

`stats` is an ordinary workflow in [`workflows.json`](../../workflows.json)
pointing at `alfresco://stats`. Rename the keyword there, or add another one
pointing at the same URL. A workflow that opens the report is never listed as
unused.

Focus sessions were not counted in the usage stats before this feature, so
the figure starts at zero on its first week. A session that ended while the
Mac slept or the app was closed counts on the day it ended, as in the
[pomodoro](../Pomodoro/README.md) view.

## Settings

In `Sources/App/Config.swift` (rebuild after a change):

- `usageReportDays` (7): the days the figures and top lists add up, today
  included.
- `usageRetentionDays` (90, shared with the usage stats): how far back
  "never run" looks.
- `usageTracking = false` turns the stats off, and this report with them.

## Code

- `UsageReport.swift`: the figures, the top lists and the unused commands,
  worked out without AppKit (checked by the self-test).
- `StatsView.swift`: the area under the launcher input.
- `StatsCommand.swift`: the `alfresco://stats` URL.
