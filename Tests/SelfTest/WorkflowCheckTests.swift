// WorkflowCheckTests.swift
//
// `Launcher --check`: which problems a workflows file reports, and with
// which severity. Tests/run-self-tests.sh also runs the binary's --check on
// the repo's workflows.json and on a broken file, for the exit status.

import Foundation

@MainActor
enum WorkflowCheckTests {
    private static func check(_ json: String) -> WorkflowCheck {
        WorkflowCheck(data: Data(json.utf8))
    }

    static func run() {
        let fresh = check(Config.defaultWorkflowsJSON)
        SelfTest.check("workflow check: the default file passes with nothing to report",
                       fresh.passed && fresh.problems.isEmpty, "got \(fresh.problems)")

        let both = check(#"""
        {"workflows": [
          {"keywords": ["w"], "title": "Here", "url": "https://example.com/"},
          {"keywords": ["w"], "title": "There", "url": "https://example.com/{query}"}
        ]}
        """#)
        SelfTest.check("workflow check: a keyword alone and with an argument is fine",
                       both.passed && both.problems.isEmpty, "got \(both.problems)")
        SelfTest.check("workflow check: the report ends with OK and the counts",
                       both.report(name: "f.json").last == #"f.json: OK (2 workflows, fallback "Search Google")"#,
                       "got \(both.report(name: "f.json"))")

        let shadowed = check(#"""
        {"workflows": [
          {"keywords": ["a"], "title": "First", "url": "https://example.com/{query}"},
          {"keywords": ["b", "a"], "title": "Second", "url": "https://example.org/{query}"},
          {"keywords": ["c", "c"], "title": "Twice", "url": "https://example.net/"}
        ]}
        """#)
        SelfTest.check("workflow check: an unreachable keyword is a warning, not a failure",
                       shadowed.passed && shadowed.problems.count == 2
                           && shadowed.problems.allSatisfy { $0.severity == .warning },
                       "got \(shadowed.problems)")
        SelfTest.check("workflow check: the warning names both workflows",
                       shadowed.problems.first?.message.contains(#""First" and "Second""#) == true,
                       "got \(shadowed.problems)")
        SelfTest.check("workflow check: a keyword listed twice in one workflow is named",
                       shadowed.problems.last?.message == #"keyword "c" is listed twice in "Twice""#,
                       "got \(shadowed.problems)")

        let missing = check(#"{"workflows": [{"keywords": ["x"], "url": "https://example.com/{query}"}]}"#)
        SelfTest.check("workflow check: a missing field fails with the hint's message",
                       !missing.passed && missing.set == nil
                           && missing.problems == [.init(severity: .error, message: #"missing "title" at .workflows[0]"#)],
                       "got \(missing.problems)")
        SelfTest.check("workflow check: a failure's report ends with FAILED",
                       missing.report(name: "f.json").last == "f.json: FAILED (1 error)",
                       "got \(missing.report(name: "f.json"))")

        let refused = check(#"""
        {"workflows": [
          {"keywords": ["ok"], "title": "Fine", "url": "https://example.com/"},
          {"keywords": ["run"], "title": "Script", "url": "file:///tmp/x.command"}
        ]}
        """#)
        SelfTest.check("workflow check: a workflow the app leaves out is an error",
                       !refused.passed && refused.set?.workflows.count == 1
                           && refused.problems.count == 1
                           && refused.problems[0].message.hasPrefix(#"refused "Script": url must start with"#),
                       "got \(refused.problems)")

        let refusedPreview = check(#"""
        {"workflows": [
          {"keywords": ["w"], "title": "Weather", "url": "https://example.com/{query}", "preview": "http://example.com/{query}"}
        ]}
        """#)
        SelfTest.check("workflow check: a refused preview is an error that keeps the workflow",
                       !refusedPreview.passed && refusedPreview.set?.workflows.count == 1
                           && refusedPreview.problems.first?.message
                               == #"refused "Weather": preview must be an https URL or start with {service}/ (its preview is left out)"#,
                       "got \(refusedPreview.problems)")

        let refusedFallback = check(#"""
        {"workflows": [], "fallback": {"title": "Local", "url": "file:///{query}"}}
        """#)
        SelfTest.check("workflow check: a refused fallback is an error",
                       !refusedFallback.passed && refusedFallback.set?.fallback == nil
                           && refusedFallback.report(name: "f.json").last == "f.json: FAILED (1 error)",
                       "got \(refusedFallback.report(name: "f.json"))")

        let notJSON = check("{ \"workflows\": [ }")
        SelfTest.check("workflow check: invalid JSON fails", !notJSON.passed && notJSON.set == nil)

        let gone = WorkflowCheck(fileURL: SelfTest.scratchFile("no-such-workflows"))
        SelfTest.check("workflow check: a missing file fails",
                       !gone.passed && gone.problems.first?.message.hasPrefix("cannot read the file") == true,
                       "got \(gone.problems)")
    }
}
