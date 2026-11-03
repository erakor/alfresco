// LoginItem.swift
//
// "Launch at Login" in the menu bar menu, through SMAppService (macOS 13+).
// It registers the bundle that is running, so it is only offered for an
// installed copy (in /Applications or ~/Applications): one registered from
// build/ would stop working as soon as build.sh replaces that bundle.

import Cocoa
import ServiceManagement

@MainActor
enum LoginItem {
    /// Whether this macOS and this process can have a login item at all: a
    /// plain binary has no bundle to register.
    static var isSupported: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static var isInstalled: Bool {
        isInstalledLocation(Bundle.main.bundleURL.path, home: NSHomeDirectory())
    }

    /// True for an app directly in /Applications or ~/Applications.
    nonisolated static func isInstalledLocation(_ bundlePath: String, home: String) -> Bool {
        let path = (bundlePath as NSString).standardizingPath
        let folder = (path as NSString).deletingLastPathComponent
        let home = (home as NSString).standardizingPath
        return path.hasSuffix(".app")
            && (folder == "/Applications" || folder == (home as NSString).appendingPathComponent("Applications"))
    }

    /// On (the app starts at login) or waiting for approval in System
    /// Settings, which also counts as asked for.
    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// Turns it on or off. Errors are shown in an alert. When macOS wants the
    /// user's approval, System Settings opens on Login Items.
    static func toggle() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if isEnabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            alert.runModal()
        }
    }
}
