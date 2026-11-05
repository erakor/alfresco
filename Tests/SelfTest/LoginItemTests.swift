// LoginItemTests.swift
//
// Where "Launch at Login" is offered. Nothing here registers a login item.

import Cocoa

@MainActor
enum LoginItemTests {
    static func run() {
        let home = "/Users/me"
        let cases: [(String, Bool)] = [
            ("/Applications/Launcher.app", true),
            ("/Users/me/Applications/Launcher.app", true),
            ("/Users/me/Applications/Launcher.app/", true),
            ("/Users/me/code/alfresco/build/Launcher.app", false),
            ("/Applications/Utilities/Launcher.app", false),
            ("/Users/other/Applications/Launcher.app", false),
            ("/Applications/Launcher", false),
        ]
        for (path, expected) in cases {
            SelfTest.check("login item: \(path) is \(expected ? "" : "not ")installed",
                           LoginItem.isInstalledLocation(path, home: home) == expected)
        }
        SelfTest.check("login item: waiting for approval says where to allow it",
                       LoginItem.toolTip(state: .needsApproval, installed: true)?.contains("Login Items") == true)
        SelfTest.check("login item: off outside Applications says where it works",
                       LoginItem.toolTip(state: .off, installed: false)?.contains("~/Applications") == true)
        SelfTest.check("login item: can only be turned on in an installed copy",
                       !LoginItem.canToggle(state: .off, installed: false)
                           && LoginItem.canToggle(state: .off, installed: true)
                           && LoginItem.canToggle(state: .on, installed: false)
                           && LoginItem.canToggle(state: .needsApproval, installed: false))
        SelfTest.check("login item: waiting for approval shows a dash",
                       LoginItem.State.needsApproval.controlState == .mixed)
        SelfTest.check("login item: on, or off in an installed copy, has no tooltip",
                       LoginItem.toolTip(state: .on, installed: false) == nil
                           && LoginItem.toolTip(state: .off, installed: true) == nil)
    }
}
