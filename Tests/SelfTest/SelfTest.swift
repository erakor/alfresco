// SelfTest.swift
//
// A runtime self-test, compiled in only with -D SELFTEST (see
// Tests/run-self-tests.sh). `Launcher --self-test <suite>` runs the suite
// inside a real NSApplication, prints a PASS or FAIL line per check and
// exits 0 when everything passed. Release builds contain none of this.
//
// ALFRESCO_SUPPORT_DIR must point at a scratch folder: the self-test build
// uses it instead of ~/Library/Application Support/Launcher, so a run never
// touches the real clipboard history or pomodoro state.

import Cocoa

@MainActor
enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    static func main(suite: String) -> Never {
        guard let directory = ProcessInfo.processInfo.environment["ALFRESCO_SUPPORT_DIR"], !directory.isEmpty else {
            FileHandle.standardError.write(Data("--self-test needs ALFRESCO_SUPPORT_DIR (a scratch folder)\n".utf8))
            exit(2)
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // Keeps WorkflowStore from creating ~/.config/alfresco/workflows.json.
        if ProcessInfo.processInfo.environment["ALFRESCO_WORKFLOWS"] == nil {
            setenv("ALFRESCO_WORKFLOWS", (directory as NSString).appendingPathComponent("workflows.json"), 1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = SelfTestRunner(suite: suite)
        app.delegate = runner
        withExtendedLifetime(runner) {
            app.run()
        }
        exit(1)
    }

    static func log(_ line: String) {
        // Unbuffered, so a run killed by its timeout still shows its lines.
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            log("PASS \(name)")
        } else {
            failed += 1
            let detail = detail()
            log("FAIL \(name)" + (detail.isEmpty ? "" : ": \(detail)"))
        }
    }

    static func finish() -> Never {
        log("\(passed) passed, \(failed) failed")
        exit(failed == 0 && passed > 0 ? 0 : 1)
    }

    /// A file in the scratch folder no other check uses.
    static func scratchFile(_ name: String) -> URL {
        let directory = ClipboardStore.directory.appendingPathComponent("unit", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }
}

@MainActor
private final class SelfTestRunner: NSObject, NSApplicationDelegate {
    private let suite: String

    init(suite: String) {
        self.suite = suite
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mode = PomodoroAlert.notificationsAvailableForSelfTest ? "app bundle" : "plain binary"
        SelfTest.log("Self-test \(suite) (\(mode))")
        switch suite {
        case "unit":
            PomodoroTests.run()
            UsageStatsTests.run()
        case "relaunch-write":
            PomodoroTests.relaunchWrite()
        case "relaunch-read":
            PomodoroTests.relaunchRead()
        case "menubar-hold":
            // Keeps running so a screenshot can be taken, then exits.
            PomodoroTests.menuBarHold()
            return
        default:
            SelfTest.log("Unknown suite \(suite); use unit, relaunch-write, relaunch-read or menubar-hold")
            exit(2)
        }
        SelfTest.finish()
    }
}

@MainActor
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    SelfTest.check(name, condition, detail())
}
