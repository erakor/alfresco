# Launcher

The Spotlight-style bar on `⌘⇧Space`. Type a command, hit Enter, and the URL
opens in your default browser. Type an app's name instead and it opens the
app.

- Frosted panel, auto-focused input, fade/slide animation.
- `Esc`, clicking outside, or pressing the hotkey again dismisses it.
- `⌘X/C/V/A/Z` work in the input even though the app has no menu bar.
- Suggestions as you type, with icons: matching apps and keywords (`p` lists `pr`); `Tab` completes, `↑` `↓` choose, `⌘1` to `⌘9` pick.

| Input          | Opens                                                             |
| -------------- | ----------------------------------------------------------------- |
| `pr 123`       | `https://github.com/<owner>/<repo>/pull/123` (`pr #123` works too) |
| `jira abc-42`  | `https://understood.atlassian.net/browse/ABC-42`                  |
| `cf 5KsDBWseXY` | `https://app.contentful.com/spaces/p0qf7j048i0q/entries/5KsDBWseXY` |
| `weather`      | `https://wttr.in/?lang=fr&m` (where you are, in French, metric); the hint shows the current weather |
| `weather paris` | `https://wttr.in/paris?lang=fr&m`                                |
| `cal`          | `https://calendar.google.com/calendar/r`; the launcher lists your next [events](../Calendar/README.md) |
| `cal standup`  | Google Calendar's search for `standup`; the launcher lists the matching events |
| `saf`, `code`, `vsc` | The installed app whose name matches (Safari, Visual Studio Code) |
| `pomo`         | Starts a 25 min [pomodoro](../Pomodoro/README.md), or pauses / resumes it (nothing opens) |
| anything else  | `https://www.google.com/search?q=...`                             |

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
      "description": "PR by number, e.g. pr 12",
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
| `keywords`   | One or more single words, matched case-insensitively. First match wins. A keyword can be used by two workflows, one with `{query}` and one without: the keyword alone opens the second, the keyword plus an argument the first. |
| `title`      | Shown in the hint as you type.                                              |
| `description` | Optional help text. Shown in the hint when you type the keyword without its argument (Enter does nothing until you add one), and under the workflow in the menu bar's **Workflows** submenu. |
| `url`        | `{query}` is replaced with the percent-encoded argument. Without `{query}`, typing the keyword alone opens the URL. An `alfresco://` URL is run by the launcher itself instead of being opened (see [Pomodoro](../Pomodoro/README.md)); one it doesn't know beeps. |
| `preview`    | Optional http(s) URL, filled in like `url` (`{query}` only if `url` has it). While the input matches the workflow, the launcher fetches it and shows the first line of the plain-text answer in the hint, e.g. the weather. It waits until you pause typing and keeps answers for 10 minutes; if the request fails, the hint just shows the title. What you type after the keyword is sent to that server. Not allowed on `fallback`. |
| `transforms` | Optional, applied in order to the argument: `uppercase`, `lowercase`, `trim`, `stripPrefix:<text>`, `stripSuffix:<text>`. |
| `fallback`   | Optional. Used when nothing matches; its `url` must contain `{query}`.      |

If the file has a mistake or is missing, the launcher keeps using the last good
version and shows the error in the hint area (hover it for the full message).

The menu bar's **Workflows** submenu lists every workflow with its description;
picking one opens the launcher with its keyword already typed.

### Suggestions

A list under the input shows what you could mean, one row each with an icon,
a title and a subtitle:

- The installed apps whose name matches (with their path), best match first
  (see [Apps](#apps)). That first app is highlighted because `Enter` opens it;
  `⌘↩` searches instead.
- While you type a single word, the workflows whose keyword starts with it
  (`p` shows `pr`), with their keyword and description, the ones you run most
  first. Their icon is the app that opens the URL (your browser for web links).

Up to nine rows show (more keywords scroll). The highlighted row shows `↩`,
the others `⌘2` to `⌘9`: that shortcut takes the row directly. `↑` `↓` move
the highlight. `Tab` completes the highlighted row, else the first, adding a
space when a workflow needs an argument so you can keep typing. `Enter` (or a
click, or `⌘N`) on a workflow row completes it and opens it if it needs
nothing more; on an app row it opens the app. With no row highlighted,
`Enter` runs what is typed, as before (so `p` alone still searches Google
when no app matches). The workflow rows go away once the word is a whole
keyword or you type a space.

## Apps

When what you type isn't a workflow keyword, the launcher looks for an
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
- Workflow keywords always win: `weather` runs the `weather` workflow, not
  the Weather app. Only the whole keyword counts, so `weath` opens the app.
- Apps are found in `/Applications`, `/System/Applications`,
  `/System/Library/CoreServices/Applications` and `~/Applications`, each with
  one level of subfolders (`Utilities`), plus Finder. The list is refreshed
  when the launcher opens, at most once a minute, so new apps show up
  without a restart.

## Settings

In `Sources/App/Config.swift` (rebuild after a change):

- `hotKey`: `.commandShiftSpace` (default) or `.optionSpace`. macOS 15+ rejects
  Option-only hotkeys, so `.optionSpace` only works on macOS 14 and earlier.
- `workflowsSource`: how the workflows file is found (see above).
- `appSearch`: set to `false` to turn app launching off. `appFolders` lists
  where apps are looked for, `appRescanInterval` (60 s) how often.

## Code

- `LauncherController.swift`: the launcher panel (input, hint line, Enter and
  `⌘↩` handling, routing of `alfresco://` URLs to the app).
- `Workflows.swift`: the `workflows.json` model, reloading and command parsing.
- `SuggestionListView.swift`: the list under the input (apps and keywords,
  with icons and `⌘1` to `⌘9`).
- `AppIndex.swift`: installed apps, name matching and ranking by use.
- `PreviewFetcher.swift`: fetches a workflow's `preview` URL for the hint.
