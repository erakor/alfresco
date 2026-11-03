#!/usr/bin/env bash
# Decodes a workflows file with the app's real decoding code and runs sample
# inputs through CommandParser, without building or launching the app.
#
#   check.sh [workflows.json] [input ...]
#   check.sh workflows.json "/pr #12" "/jira abc-42" "/jira" "hello world"
#
# It compiles Sources/Launcher/Workflows.swift and WorkflowCheck.swift as is
# (the verdict is the one `Launcher --check` prints), plus a stub Config that
# carries the real Config.defaultWorkflowsJSON, so it tracks the source
# automatically.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../../../.." && pwd)"
file="$(cd "$(dirname "${1:-$repo/workflows.json}")" && pwd)/$(basename "${1:-$repo/workflows.json}")"
shift || true

work="$(mktemp -d "${TMPDIR:-/tmp}/alfresco-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

workflows="$repo/Sources/Launcher/Workflows.swift"
workflowCheck="$repo/Sources/Launcher/WorkflowCheck.swift"
config="$repo/Sources/App/Config.swift"
for f in "$workflows" "$workflowCheck" "$config"; do
  [ -f "$f" ] || { echo "check.sh: $f not found; update this script" >&2; exit 2; }
done
grep -q 'static let defaultWorkflowsJSON' "$config" || {
  echo "check.sh: Config.defaultWorkflowsJSON changed; update this script" >&2; exit 2; }
grep -q '^ *static let workflowURLSchemes: Set<String> = \[.*\]$' "$config" || {
  echo "check.sh: Config.workflowURLSchemes changed; update this script" >&2; exit 2; }
grep -q '^ *static let commandPrefix: String? = ' "$config" || {
  echo "check.sh: Config.commandPrefix changed; update this script" >&2; exit 2; }
grep -q '^ *static let commandListKeyword = ' "$config" || {
  echo "check.sh: Config.commandListKeyword changed; update this script" >&2; exit 2; }

# The real Config.swift needs Carbon and the app bundle, so only the default
# workflows JSON, the allowed URL schemes and the command prefix are taken
# from it.
{
  echo 'import Foundation'
  echo 'enum Config {'
  echo '    static let workflowsSource: (url: URL, isFallback: Bool) = (URL(fileURLWithPath: "/dev/null"), false)'
  grep '^ *static let workflowURLSchemes: Set<String> = ' "$config"
  grep '^ *static let commandPrefix: String? = ' "$config"
  grep '^ *static let commandListKeyword = ' "$config"
  awk '/static let defaultWorkflowsJSON/{on=1} on{print} on && /"""#/{exit}' "$config"
  echo '}'
} > "$work/config.swift"
cat > "$work/main.swift" <<'SWIFT'
import Foundation
let args = CommandLine.arguments
// The same check as `Launcher --check`.
let check = WorkflowCheck(fileURL: URL(fileURLWithPath: args[1]))
for line in check.report(name: (args[1] as NSString).lastPathComponent) { print(line) }
guard check.passed, let set = check.set else { exit(1) }
// Where what is typed goes without a keyword (Enter on anything unmatched)
// and while typing (previews): worth a look whenever the file changes.
func host(_ template: String) -> String {
    URLComponents(string: template.replacingOccurrences(of: "{query}", with: "x"))?.host ?? template
}
if let fallback = set.fallback { print("Fallback sends unmatched input to: \(host(fallback.url))") }
let previewHosts = Set(set.workflows.compactMap { $0.preview.map(host) }).sorted()
if !previewHosts.isEmpty { print("Previews send typed arguments to: \(previewHosts.joined(separator: ", "))") }
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

# Anything on stderr (NSLog) is silenced, so only the report prints.
swiftc -swift-version 6 "$work/main.swift" "$workflows" "$workflowCheck" "$work/config.swift" -o "$work/check" 2> "$work/build.log" || {
  cat "$work/build.log" >&2; echo "check.sh: harness failed to compile (see above)" >&2; exit 2; }
"$work/check" "$file" "$@" 2>/dev/null
