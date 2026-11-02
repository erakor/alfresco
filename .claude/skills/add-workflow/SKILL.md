---
name: add-workflow
description: Add, change, or remove a keyword in alfresco's workflows.json (keyword → URL shortcuts like "pr 12" or "jira abc-42"), and check the file with the app's own decoder. Use when the user wants a new launcher keyword, a different URL or transform for one, or asks why a keyword doesn't work.
---

# Add or change a workflow

`workflows.json` is data, not code. The running app re-reads it when its
modification date changes, so there's no rebuild or relaunch. The field
reference is the table under "Workflows" in `Sources/Launcher/README.md`.

## 1. Work out the entry

```json
{
  "keywords": ["pr"],
  "title": "GitHub PR",
  "description": "erakor/alfresco PR by number, e.g. pr 12",
  "url": "https://github.com/erakor/alfresco/pull/{query}",
  "transforms": ["stripPrefix:#"]
}
```

- **`keywords`**: single lowercase words (the decoder lowercases and rejects
  spaces). Short, easy to type, and not already in the file. A keyword may be
  listed twice only as one workflow with `{query}` and one without (the bare
  keyword opens the second, the keyword plus an argument the first, as
  `weather` does). Two of the same form: the first wins, the second is
  unreachable.
- **`url`**: does it take an argument?
  - With `{query}`, the keyword needs an argument. Typed alone, Enter does
    nothing and the hint shows `description`.
  - Without `{query}`, only the bare keyword matches. `kw something` goes to the
    fallback search instead, unless the same keyword also has a `{query}`
    workflow.
  - The argument is percent-encoded with the RFC 3986 unreserved set, so `/`,
    `?`, `#` and spaces are encoded too. Put `{query}` where a single encoded
    path segment or query value belongs, not where the user's text should
    become several path segments.
- **`transforms`**: cleanup applied to the argument, in order, before encoding:
  `uppercase`, `lowercase`, `trim`, `stripPrefix:<text>`, `stripSuffix:<text>`.
  Use them for how people actually paste things (`#12`, `abc-42`, a trailing
  `/`).
- **`description`**: always include one, with a concrete example ("…, e.g.
  jira abc-42"). It's the only help shown while typing and in the menu bar's
  Workflows submenu.
- **`title`**: short. It's shown as "<title> <argument>" in the hint.
- **`preview`** (optional): an http(s) URL returning one short line of plain
  text, shown in the hint before Enter (the `weather` workflows use wttr.in's
  `?format=`). Same `{query}` rules as `url`. Pre-encode literal `%` as `%25`
  (`format=%25t`), since a bare `%t` is not a valid URL. Only add one when the
  user wants it: the typed argument is sent to that server while typing.

If the user gave only a URL or a site name, find a real example URL to pin down
where the ID goes rather than guessing the path. Ask when it's ambiguous.

## 2. Edit

Add the entry to the `workflows` array in the repo's `workflows.json`, keeping
the file's two-space formatting. The `fallback` object is optional, and its URL
must contain `{query}`.

## 3. Check

```bash
.claude/skills/add-workflow/scripts/check.sh workflows.json "<kw> <sample arg>" "<kw>" "<other existing kw> <arg>"
```

The script compiles the real `Workflow`/`WorkflowSet`/`CommandParser` code from
`Sources/Launcher/Workflows.swift`, so its verdict matches the app's. It prints:
- `INVALID: …` (exit 1) with the same message the app shows in its hint area;
- a warning for any keyword used twice in the same form (both with `{query}`
  or both without);
- for each sample input, the label and final URL, or "Enter does nothing".

Try the realistic inputs (with the `#`, the lowercase key, and so on) and make
sure the URLs are exactly right. If it prints "… not found" or "… changed", the
source layout moved; fix the paths or the `awk` range in the script.

## 4. Report

Show the user the entry and the sample expansions. They can try it right away
(⌘⇧Space). Say that it needs no rebuild, unless the app they run reads a
different file: an `ALFRESCO_WORKFLOWS` LaunchAgent pointing elsewhere, or a
build made before the repo moved.

`workflows.json` is committed, so commit it like any other change if asked. The
current entries include Understood's Jira and Contentful URLs. That's expected
in this repo, so don't strip them.
