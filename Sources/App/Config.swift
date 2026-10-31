// Config.swift
//
// Compile-time settings: hotkeys, menu bar icon, clipboard limits, and where
// the workflows file is found. Edit and rebuild to change them.

import Foundation
import Carbon.HIToolbox

// MARK: - Configuration

/// A system-wide shortcut registered through RegisterEventHotKey.
struct HotKey: Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    static let commandShiftSpace = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(cmdKey | shiftKey),
        display: "⌘⇧Space"
    )

    /// macOS 15 and later refuse hotkeys whose only modifiers are Option or
    /// Option+Shift, so this preset only works on macOS 14 and earlier.
    static let optionSpace = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey),
        display: "⌥Space"
    )

    /// Overrides ⌘⌥C inside apps while the launcher runs (Finder's "Copy as
    /// Pathname", the browsers' web inspector).
    static let commandOptionC = HotKey(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(cmdKey | optionKey),
        display: "⌘⌥C"
    )
}

enum Config {
    static let hotKey = HotKey.commandShiftSpace
    static let showMenuBarIcon = true

    /// Opens the clipboard history panel.
    static let clipboardHotKey = HotKey.commandOptionC
    /// Copied items older than this are deleted, from memory and from disk.
    static let clipboardRetention: TimeInterval = 24 * 60 * 60
    /// Oldest items are dropped beyond this count.
    static let clipboardMaxItems = 500
    /// Larger copies are not recorded.
    static let clipboardMaxTextBytes = 256 * 1024
    /// Images larger than this, once encoded as PNG, are not recorded.
    static let clipboardMaxImageBytes = 20 * 1024 * 1024
    /// Images with more pixels than this are turned away before they are
    /// decoded (40 MP is a bit more than an 8K image).
    static let clipboardMaxImagePixels = 40_000_000
    /// macOS has no clipboard-change notification, so the clipboard's change
    /// counter is checked this often (in seconds). The check itself is cheap.
    static let clipboardPollInterval: TimeInterval = 0.5

    /// Where workflows.json is read from, first match wins:
    /// 1. the `ALFRESCO_WORKFLOWS` environment variable;
    /// 2. the `AlfrescoWorkflowsFile` Info.plist key, which build.sh sets to
    ///    the repo's workflows.json;
    /// 3. workflows.json next to the executable (a plain binary built in the
    ///    repo);
    /// 4. ~/.config/alfresco/workflows.json, created on first launch.
    /// The file is re-read whenever it changes, so no rebuild is needed.
    static let workflowsSource: (url: URL, isFallback: Bool) = {
        let fileManager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["ALFRESCO_WORKFLOWS"], !path.isEmpty {
            return (URL(fileURLWithPath: (path as NSString).expandingTildeInPath), false)
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "AlfrescoWorkflowsFile") as? String, !path.isEmpty {
            return (URL(fileURLWithPath: (path as NSString).expandingTildeInPath), false)
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("workflows.json")
            if fileManager.fileExists(atPath: sibling.path) { return (sibling, false) }
        }
        let home = fileManager.homeDirectoryForCurrentUser
        return (home.appendingPathComponent(".config/alfresco/workflows.json"), true)
    }()

    /// Used until workflows.json loads, and to seed the ~/.config fallback.
    /// The real workflows live in the repo's workflows.json.
    static let defaultWorkflowsJSON = #"""
        {
          "workflows": [],
          "fallback": {
            "title": "Search Google",
            "url": "https://www.google.com/search?q={query}"
          }
        }

        """#
}
