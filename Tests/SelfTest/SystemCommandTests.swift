// SystemCommandTests.swift
//
// alfresco://system/... parsing, and that the lock function is still there.
// Nothing here actually sleeps or locks the runner.

import Foundation

@MainActor
enum SystemCommandTests {
    static func run() {
        let cases: [(String, SystemCommand?)] = [
            ("alfresco://system/sleep", .sleep),
            ("alfresco://system/lock", .lock),
            ("alfresco://system/displaysleep", .displaySleep),
            ("ALFRESCO://System/Lock/", .lock),
            ("alfresco://system/", nil),
            ("alfresco://system/shutdown", nil),
            ("alfresco://pomodoro/sleep", nil),
            ("https://system/sleep", nil),
        ]
        for (string, expected) in cases {
            let parsed = URL(string: string).flatMap(SystemCommand.init(url:))
            SelfTest.check("system command \(string)", parsed == expected, "got \(String(describing: parsed))")
        }
        SelfTest.check("system: pomodoro URLs are not system commands",
                       URL(string: "alfresco://pomodoro/toggle").flatMap(SystemCommand.init(url:)) == nil)
        SelfTest.check("internal URL: feature is the lowercased host",
                       URL(string: "Alfresco://System/sleep").flatMap(InternalURL.feature(of:)) == "system")
        SelfTest.check("internal URL: other schemes have no feature",
                       URL(string: "https://system/sleep").flatMap(InternalURL.feature(of:)) == nil)
        SelfTest.check("internal URL: action is trimmed and lowercased",
                       URL(string: "alfresco://pomodoro/%20Pause/").flatMap { InternalURL.action(of: $0, feature: "pomodoro") } == "pause")
        SelfTest.check("system: SACLockScreenImmediate resolves", SystemCommand.lockAvailableForSelfTest)
        SelfTest.check("system: pmset is executable", FileManager.default.isExecutableFile(atPath: "/usr/bin/pmset"))
    }
}
