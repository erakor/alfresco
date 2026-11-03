// LoginItemTests.swift
//
// Where "Launch at Login" is offered. Nothing here registers a login item.

import Foundation

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
    }
}
