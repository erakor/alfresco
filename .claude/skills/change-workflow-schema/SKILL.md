---
name: change-workflow-schema
description: Checklist for changing the workflows.json format in alfresco — a new field on a workflow, a new argument transform, new validation, or a changed meaning for an existing field. Use whenever a change touches Workflow, WorkflowSet, ArgumentTransform, or CommandParser's handling of them.
---

# Change the workflows.json schema

The schema lives in four places that must stay in agreement, and users' existing
`workflows.json` files must keep loading. Go through every step, even for a
"small" field.

## 1. Decoding (`Launcher.swift`, `// MARK: - Workflows`)

- **New workflow field**: add the property to `Workflow`, a case to its
  `CodingKeys` (map a JSON name that differs from the Swift name, as
  `help = "description"` does), and decode it in `init(from:)`.
  - New fields must be **optional** (`decodeIfPresent` + a default) so files
    without them still load. Only make a field required if the user explicitly
    accepts breaking existing files.
  - Normalize on the way in, as `keywords` (trim + lowercase) and `description`
    (trim, empty → nil) do.
- **New transform**: add a case to `ArgumentTransform`, its string form in the
  `switch (name, value.isEmpty)` (no-value transforms match `true`,
  `name:<value>` ones `false`), its behavior in `apply(to:)`, and the new name
  in the "unknown transform" error message, which lists every valid one.
- **Validation**: throw `DecodingError.dataCorruptedError(forKey:in:debugDescription:)`
  with a short, specific message, as the "keywords must be single words" and
  "fallback url must contain {query}" checks do. The `debugDescription` *is*
  the text the user sees.
- Keep the types `Sendable`. The build uses `-swift-version 6`.

## 2. Error messages (`WorkflowStore.describe`)

`describe` turns `DecodingError`s into the one-line message shown in the
launcher's hint area. Check that the new failure modes read well there: a
missing required key, a wrong type, or your custom validation. Adjust
`describe` only if a new error kind comes out unreadable.

## 3. Behavior (`CommandParser`, `LauncherController`, menu)

If the field changes what happens, wire it in where the existing fields are
used: `CommandParser.parse` / `expand` for URLs, `workflowAwaitingArgument` and
the launcher hint for help text, and `AppDelegate.menuNeedsUpdate` for the
Workflows submenu. `grep -n 'takesArgument\|\.help\|\.transforms' *.swift`
finds the use sites.

## 4. Docs and defaults

- **`README.md`**: update the field table under "## Workflows" (and the example
  JSON above it if the field is commonly used). For a transform, add it to the
  `transforms` row.
- **`Config.defaultWorkflowsJSON`**: it seeds `~/.config/alfresco/workflows.json`
  and is decoded at startup by `WorkflowSet.builtIn` with a `try!`. If it no
  longer decodes, the app crashes on launch. Update it only if the new field
  should appear in a fresh file.
- **`CLAUDE.md`**: update the Workflows bullet if the architecture description
  changed (a new type, or a new reload/validation rule).
- **`.claude/skills/add-workflow/SKILL.md`**: update its field guidance so new
  entries use the new field correctly.

## 5. Verify

```bash
swiftc -O -parse-as-library -swift-version 6 *.swift -o "$(mktemp -d)/Launcher"   # must be clean
.claude/skills/add-workflow/scripts/check.sh workflows.json "<inputs exercising the change>"
```

Then, with scratch JSON files in the scratchpad (not the repo's file), run
`check.sh` against:
- the repo's current `workflows.json` unchanged (backward compatibility);
- a file using the new field correctly;
- a file using it wrongly, to read the error message as the user would see it.

`check.sh` compiles the code between `// MARK: - Workflows` and
`// MARK: - Global hotkeys`. If the change moves decoding code outside that
range, or makes it depend on something outside it (AppKit, other `Config`
values), update the script's extraction too. If the change affects the UI, use
the `run-app` skill for a real check.
