# Pomodoro

Type `/pomo` in the [launcher](../Launcher/README.md) and press Enter to start a
25 minute focus session. The countdown shows in the menu bar (a timer icon for
focus, a cup for breaks) for as long as a session or break is under way, and
disappears when it's over. Its menu shows where you are in the cycle ("Focus 2
of 4, 18:42 left") and has Pause / Resume, Skip and Stop.

| Input         | Does                                                                  |
| ------------- | --------------------------------------------------------------------- |
| `/pomo`       | Starts a focus session, or pauses / resumes the one running           |
| `/pomo 50`    | Starts a 50 minute focus session (1 to 180), replacing any running one |
| `/pomo pause`, `/pomo resume` | Pause or resume                                       |
| `/pomo skip`  | Ends the focus session or break now, without the alert                |
| `/pomo stop`  | Stops, and the cycle starts over                                      |

## In the launcher

While you type `/pomo` (or any command pointing at `alfresco://pomodoro/...`),
the launcher shows the timer under the input instead of the suggestion list:

- A card with the phase ("FOCUS 2 OF 4", "SHORT BREAK"), the time left
  counting down, when it ends (or "Paused"), and what comes next ("Then a
  5 min break"). Red during focus, green during a break, grey while idle or
  paused. While idle it shows the length Enter would start: 25:00, or 50:00
  for `/pomo 50`.
- Below it, the cycle so far (`●●○○`) and how many focus sessions you
  finished today. Only sessions that ran their full length count, including
  one that ended while the Mac slept or the app was closed (on the day it
  ended); skipped ones don't, and Stop doesn't reset the count. It is saved
  in `pomodoro.json` with the timer.
- The hint says what Enter will do with the timer as it is now: "↩ Start a
  25 min focus session", "↩ Pause the focus session", "↩ Resume the short
  break", "↩ Replace the focus session with a 50 min focus session". When
  the action wouldn't apply, it says why instead ("Nothing to pause",
  "Already running") and Enter beeps.

- After a focus session comes a 5 minute break, or a 15 minute one after
  every 4th session. The break starts by itself. When it ends the timer stops
  until you type `/pomo` again.
- When a session or break runs out, a sound plays (`Glass`). When you run
  `build/Launcher.app`, a macOS notification is shown too. macOS asks once
  for permission the first time you start a session. The plain `./Launcher`
  binary only plays the sound, since notifications need an app bundle.
- If the Mac sleeps through the end of a session or break, the sound and
  notification come as soon as it wakes, and a break that follows is timed
  from then. If it wakes much later (after the break would already have
  ended, say overnight), there's no alert: a focus session's break waits
  paused in the menu bar, as after quitting and relaunching.
- The timer is saved in `~/Library/Application Support/Launcher/pomodoro.json`,
  so quitting or rebuilding mid-session keeps the countdown going. A phase
  that ran out while the app was closed moves on to the next one, paused.
- The `pomo` keyword is two ordinary workflows in
  [`workflows.json`](../../workflows.json) pointing at
  `alfresco://pomodoro/toggle` and `alfresco://pomodoro/{query}`. Rename the
  keyword or add others (say `focus` → `alfresco://pomodoro/50`, typed `/focus`) there.
  The actions are `toggle`, `start`, `pause`, `resume`, `skip`, `stop` and a
  number of minutes.

## Settings

In `Sources/App/Config.swift` (rebuild after a change):

- `pomodoroFocus` (25 min), `pomodoroShortBreak` (5 min), `pomodoroLongBreak`
  (15 min), `pomodoroSessionsBeforeLongBreak` (4).
- `pomodoroAutoStartBreaks` (`true`; when `false`, a break waits paused in the
  menu bar until you resume it).
- `pomodoroSound` (`"Glass"`, any name from `/System/Library/Sounds`).

## Code

- `PomodoroTimer.swift`: the timer, its cycle, today's finished sessions
  and its saved state.
- `PomodoroCommand.swift`: parses `alfresco://pomodoro/...` URLs, and says
  what one would do now (the launcher's hint).
- `PomodoroView.swift`: the timer under the launcher input.
- `PomodoroStatusItem.swift`: the menu bar countdown and its menu.
- `PomodoroAlert.swift`: the sound and the notification.
