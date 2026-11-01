#!/usr/bin/env bash
# Decodes a workflows file with the app's real decoding code and runs sample
# inputs through CommandParser, without building or launching the app.
#
#   check.sh [workflows.json] [input ...]
#   check.sh workflows.json "pr #12" "jira abc-42" "jira" "hello world"
#
# It compiles Sources/Launcher/Workflows.swift as is, plus a stub Config that
# carries the real Config.defaultWorkflowsJSON, so it tracks the source
# automatically.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../../../.." && pwd)"
file="$(cd "$(dirname "${1:-$repo/workflows.json}")" && pwd)/$(basename "${1:-$repo/workflows.json}")"
shift || true

work="$(mktemp -d "${TMPDIR:-/tmp}/alfresco-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

workflows="$repo/Sources/Launcher/Workflows.swift"
config="$repo/Sources/App/Config.swift"
for f in "$workflows" "$config"; do
  [ -f "$f" ] || { echo "check.sh: $f not found; update this script" >&2; exit 2; }
done
grep -q 'static let defaultWorkflowsJSON' "$config" || {
  echo "check.sh: Config.defaultWorkflowsJSON changed; update this script" >&2; exit 2; }

# The real Config.swift needs Carbon and the app bundle, so only the default
# workflows JSON is taken from it.
{
  echo 'import Foundation'
  echo 'enum Config {'
  echo '    static let workflowsSource: (url: URL, isFallback: Bool) = (URL(fileURLWithPath: "/dev/null"), false)'
  awk '/static let defaultWorkflowsJSON/{on=1} on{print} on && /"""#/{exit}' "$config"
  echo '}'
} > "$work/config.swift"
cat > "$work/main.swift" <<'SWIFT'
import Foundation
let args = CommandLine.arguments
let store = WorkflowStore(fileURL: URL(fileURLWithPath: args[1]), createsMissingFile: false)
if let error = store.loadError {
    print("INVALID: \(error)")
    exit(1)
}
let set = store.current
print("OK: \(set.workflows.count) workflows, fallback \"\(set.fallback.title)\"")
// A keyword may appear once with {query} and once without; a second use of
// the same form is unreachable.
var seen: [String: String] = [:]
for w in set.workflows {
    for k in w.keywords {
        let form = "\(k)|\(w.takesArgument)"
        let kind = w.takesArgument ? "with an argument" : "alone"
        if let other = seen[form] { print("WARNING: keyword \"\(k)\" \(kind) is used by \"\(other)\" and \"\(w.title)\"; the first wins") }
        else { seen[form] = w.title }
    }
}
for input in args.dropFirst(2) {
    if let w = set.workflowAwaitingArgument(input) {
        print("\(input)  ->  (Enter does nothing; hint: \(w.help ?? w.title))")
    } else if let command = CommandParser.parse(input, using: set) {
        print("\(input)  ->  \(command.label)  ->  \(command.url.absoluteString)")
        if let preview = command.preview { print("    preview: \(preview.absoluteString)") }
    } else {
        print("\(input)  ->  (nothing)")
    }
}
SWIFT

# NSLog output from WorkflowStore goes to stderr and is silenced, so only the
# report prints.
swiftc -swift-version 6 "$work/main.swift" "$workflows" "$work/config.swift" -o "$work/check" 2> "$work/build.log" || {
  cat "$work/build.log" >&2; echo "check.sh: harness failed to compile (see above)" >&2; exit 2; }
"$work/check" "$file" "$@" 2>/dev/null
