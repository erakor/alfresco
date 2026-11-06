# Launcher

The Spotlight-style bar on `⌘Space`. Type a command (`/pr 12`), hit Enter,
and the URL opens in your default browser. Type an app's name instead and it
opens the app; anything else is searched for. Type `/` (or `/help`) to list
every command.

- Frosted panel, auto-focused input, fade/slide animation.
- `Esc`, clicking outside, or pressing the hotkey again dismisses it.
- `⌘X/C/V/A/Z` work in the input even though the app has no menu bar.
- Suggestions as you type, with icons: matching apps, and commands once you type `/` (`/p` lists `/pr`); `Tab` completes, `↑` `↓` choose, `⌘1` to `⌘9` pick.
- With nothing typed, your commands show as [cards](#command-cards), the most used first; click one to type it.

| Input          | Opens                                                             |
| -------------- | ----------------------------------------------------------------- |
| `/` or `/help` | Nothing: lists every command                                      |
| `/pr 123`      | `https://github.com/<owner>/<repo>/pull/123` (`/pr #123` works too) |
| `/jira abc-42` | `https://understood.atlassian.net/browse/ABC-42`                  |
| `/cf 5KsDBWseXY` | `https://app.contentful.com/spaces/p0qf7j048i0q/entries/5KsDBWseXY` |
| `/weather`     | `https://wttr.in/?lang=fr&m` (where you are, in French, metric); the hint shows the current weather |
| `/weather paris` | `https://wttr.in/paris?lang=fr&m`                               |
| `/cal`         | `https://calendar.google.com/calendar/r`; the launcher lists your next [events](../Calendar/README.md) |
| `/cal standup` | Google Calendar's search for `standup`; the launcher lists the matching events |
| `/cal demain`  | Google Calendar; the launcher lists tomorrow's events (also `lundi`, `12/11`, `25 dec`) |
| `/pomo`        | Starts a 25 min [pomodoro](../Pomodoro/README.md), or pauses / resumes it (nothing opens); the launcher shows the timer and the hint says what Enter will do |
| `/zz`, `/lockscreen`, `/displaysleep` | Sleep, lock the screen, display off ([System](../System/README.md)) |
| `saf`, `code`, `vsc` | The installed app whose name matches (Safari, Visual Studio Code) |
| `= 3*14`, `= 10 km in mi`, `time tokyo`, `uuid`, `now`, `days until 25/12`, `week` | Nothing: a [built-in](../BuiltIns/README.md) shows the answer in the hint and Enter copies it |
| anything else  | `https://www.google.com/search?q=...`                             |

## Commands

Every workflow keyword is typed after `/` (`Config.commandPrefix`), so a word
you type on its own never runs a command by accident: `zz` alone is searched
for (or opens an app named like it), `/zz` puts the Mac to sleep.

- `/` alone, or `/help`, lists every command with its description. `↓` picks
  one, `Tab` completes it.
- Input starting with `/` is always a command: one no workflow has (`/nope`)
  beeps and the hint says so, rather than searching Google for it. `⌘↩`
  still searches for it as typed (the hint says so), so `/r/swift` or a
  pasted path can be looked up. That holds for a known command too: `⌘↩`
  on `/pr 12` searches for `/pr 12`, Enter opens the PR.
- The keyword follows the `/` directly: `/ zz` (a stray slash, then a word)
  runs nothing and beeps.
- Keywords in `workflows.json` are written without the `/` (`"pr"`); a
  keyword written with it (`"/pr"`) means the same.
- Set `Config.commandPrefix` to `nil` to type keywords bare again, as before
  (no `/` list then).


## Workflows

A workflow maps a keyword to a URL. They live in [`workflows.json`](../../workflows.json)
at the root of this repo. Open it from the menu bar icon (**Edit Workflows…**)
or any editor. Changes apply the next time you open the launcher; no rebuild or
restart needed.

`build.sh` records the absolute path of the repo's `workflows.json` in the app,
so the installed `Launcher.app` keeps reading it from the repo. If you move the
repo, rebuild.

The app looks for the file in this order:

1. The `ALFRESCO_WORKFLOWS` environment variable, if set.
2. The path `build.sh` recorded in `Launcher.app`.
3. `workflows.json` next to the executable (a plain binary built in the repo).
4. `~/.config/alfresco/workflows.json`, created with just the Google fallback
   if nothing else is found.

```json
{
  "workflows": [
    {
      "keywords": ["pr"],
      "title": "GitHub PR",
      "description": "PR by number, e.g. /pr 12",
      "url": "https://github.com/your-org/your-repo/pull/{query}",
      "transforms": ["stripPrefix:#"]
    },
    {
      "keywords": ["gh", "github"],
      "title": "GitHub notifications",
      "url": "https://github.com/notifications"
    }
  ],
  "fallback": {
    "title": "Search Google",
    "url": "https://www.google.com/search?q={query}"
  }
}
```

| Field        | Meaning                                                                    |
| ------------ | -------------------------------------------------------------------------- |
| `keywords`   | One or more single words, matched case-insensitively and typed after `/` ([Commands](#commands)). First match wins. A keyword can be used by two workflows, one with `{query}` and one without: the keyword alone opens the second, the keyword plus an argument the first. |
| `title`      | Shown in the hint as you type.                                              |
| `description` | Optional help text. Shown in the hint when you type the keyword without its argument (Enter does nothing until you add one), and under the workflow in the menu bar's **Workflows** submenu. |
| `url`        | `{query}` is replaced with the percent-encoded argument. Without `{query}`, typing the keyword alone opens the URL. It must start with `https:`, `http:`, `mailto:` or `alfresco:` (`Config.workflowURLSchemes`; add an app's own scheme there and rebuild to use it), and `{query}` can't be part of the scheme, so it can never open a local file or app. A workflow that breaks this rule is left out and named in the hint when the input is empty; the rest of the file still works. A refused `fallback` is not replaced: input no keyword takes then goes nowhere (Enter beeps, apps still open) until it is fixed, rather than to a search you didn't choose. An `alfresco://` URL is run by the launcher itself instead of being opened (see [Pomodoro](../Pomodoro/README.md) and [System](../System/README.md)); one it doesn't know beeps. |
| `preview`    | Optional https URL (not http: what you type goes into it; an `http:` preview, or one using `{query}` when `url` doesn't, is left out and reported, and the workflow still runs without it), filled in like `url` (`{query}` only if `url` has it). While the input matches the workflow, the launcher fetches it and shows the first line of the plain-text answer in the hint, e.g. the weather. It waits until you pause typing and keeps answers for 10 minutes; if the request fails, the hint just shows the title. What you type after the keyword is sent to that server. Not allowed on `fallback`. |
| `transforms` | Optional, applied in order to the argument: `uppercase`, `lowercase`, `trim`, `stripPrefix:<text>`, `stripSuffix:<text>`. |
| `fallback`   | Optional. Used when nothing matches; its `url` must contain `{query}`.      |

If the file has a mistake or is missing, the launcher keeps using the last good
version and shows the error in the hint area (hover it for the full message).

### Checking the file

```bash
./Launcher --check workflows.json            # or build/Launcher.app/Contents/MacOS/Launcher
./Launcher --check                           # the file the app reads (the order above)
```

`--check` decodes each file with the app's own code, prints what is wrong and
exits without starting the app (it works while the app runs). With no file,
a `~/.config/alfresco/workflows.json` that doesn't exist yet is OK: the app
writes the default file there when it starts. It exits 1 if a
file doesn't load, or if the app would leave part of it out (a refused `url`,
`preview` or `fallback`); a keyword that can never run, because an earlier
workflow of the same form has it, is a warning and still exits 0:

```
workflows.json: error: missing "title" at .workflows[3]
workflows.json: FAILED (1 error)
```

CI runs it on the repo's `workflows.json`.

The menu bar's **Workflows** submenu lists every workflow with its description;
picking one opens the launcher with its command already typed (`/pr `).

### Suggestions

A list under the input shows what you could mean, one row each with an icon,
a title and a subtitle:

- The installed apps whose name matches (with their path), best match first
  (see [Apps](#apps)). That first app is highlighted because `Enter` opens it;
  `⌘↩` searches instead.
- While you type `/` and a single word, the workflows whose keyword starts
  with it (`/p` shows `/pr`), with their command and description, the ones
  you run most first; `/` or `/help` shows them all, in file order. Their
  icon is the app that opens the URL (your browser for web links).

Up to nine rows show (more keywords scroll). The highlighted row shows `↩`,
the others `⌘2` to `⌘9`: that shortcut takes the row directly. `↑` `↓` move
the highlight. `Tab` completes the highlighted row, else the first, adding a
space when a workflow needs an argument so you can keep typing. `Enter` (or a
click, or `⌘N`) on a workflow row completes it and opens it if it needs
nothing more; on an app row it opens the app. With no row highlighted,
`Enter` runs what is typed, as before (so `/p` alone beeps: no command is
`p`). The workflow rows go away once the word is a whole keyword or you type
a space. Moving the mouse over the list highlights the row under it, as `↓`
would, so `Enter` then takes that row; the highlight stays there when the
mouse leaves the list. Only a mouse movement does this: rows that change
under a resting pointer while you type leave the highlight alone.

### Command cards

While the input is empty, the commands show as cards under it, three per row
(up to 12, `Config.workflowCardLimit`), each with the icon of what it opens,
its title and its command (`/pr …`). The ones you run most come first, from
the [usage stats](../Shared/README.md#usage-stats) of the last 90 days (both
forms of a keyword count for its card); file order breaks ties, so before
you have run anything they are in `workflows.json` order.

A keyword with two workflows (`/weather` and `/weather paris`) is one card,
titled after the one without an argument. Clicking a card types its command
in the input, followed by a space when it can take an argument (`/pr `,
`/weather `), and the cards go away: type the argument, or press `Enter` to
run it (`/weather ` alone runs the bare form). Nothing runs on the click
itself, not even `/zz`. Typing anything, a space aside, hides the cards too;
clearing the input brings them back. Hover a card for its description.

## Apps

When what you type doesn't start with `/`, the launcher looks for an
installed app with that name. The hint shows `↩ Open Safari` and the
magnifying glass turns into the app's icon; Enter opens the app (or brings it
forward if it's already running). Press `⌘↩` to search for the text instead.

- Matching ignores case and accents, and picks, in order: the exact name, a
  name starting with what you typed (`saf`), a word of the name (`code`,
  `studio code` for Visual Studio Code), then the initials (`vsc`). Ties go
  to the shorter name, then alphabetical order.
- The list learns: apps you open often move up, enough to beat a closer name
  (open Visual Studio Code a few dozen times and `s` puts it above Safari).
  An app whose name you type in full always comes first. This uses the
  [usage stats](../Shared/README.md#usage-stats) of the last 90 days, so it
  stops (and matching goes back to names only) if you turn those off.
- Both the name Finder shows and the file name count, so system apps match
  in English and in your language (`calculator` and `calculatrice`).
- Commands never take an app's place: `weather` opens the Weather app,
  `/weather` runs the `weather` workflow.
- [Built-ins](../BuiltIns/README.md) come before apps too: `time tokyo` shows
  the time in Tokyo. `time` alone, or `time ma`, still finds Time Machine.
- Apps are found in `/Applications`, `/System/Applications`,
  `/System/Library/CoreServices/Applications` and `~/Applications`, each with
  one level of subfolders (`Utilities`), plus Finder. The list is refreshed
  when the launcher opens, at most once a minute, so new apps show up
  without a restart.

## Settings

In `Sources/App/Config.swift` (rebuild after a change):

- `hotKey`: `.commandSpace` (default), `.commandShiftSpace` or `.optionSpace`.
  `.commandSpace` is Spotlight's shortcut, so turn it off for Spotlight first
  (System Settings > Keyboard > Keyboard Shortcuts > Spotlight), or the hotkey
  can't be registered. macOS 15+ rejects Option-only hotkeys, so `.optionSpace`
  only works on macOS 14 and earlier.
- `workflowsSource`: how the workflows file is found (see above).
- `commandPrefix` (`"/"`): typed before every keyword; `nil` types them bare.
- `workflowCardLimit` (12): how many [command cards](#command-cards) the empty
  input shows at most; `nil` turns them off.
  `commandListKeyword` (`"help"`): `/help` lists the commands, unless a
  workflow uses that keyword.
- `appSearch`: set to `false` to turn app launching off. `appFolders` lists
  where apps are looked for, `appRescanInterval` (60 s) how often.

## Code

- `LauncherController.swift`: the launcher panel (input, hint line, Enter and
  `⌘↩` handling, routing of `alfresco://` URLs to the app, copying a
  built-in's answer). The built-ins themselves are in
  [`Sources/BuiltIns`](../BuiltIns/README.md).
- `Workflows.swift`: the `workflows.json` model, reloading and command parsing.
- `WorkflowCheck.swift`: `Launcher --check`, which reports what is wrong with a
  workflows file.
- `SuggestionListView.swift`: the list under the input (apps and keywords,
  with icons and `⌘1` to `⌘9`).
- `WorkflowCardsView.swift`: the command cards under the empty input, how
  they are grouped and sorted, and the workflow icons both use.
- `AppIndex.swift`: installed apps, name matching and ranking by use.
- `PreviewFetcher.swift`: fetches a workflow's `preview` URL for the hint.
