// LoginItem.swift
//
// "Launch at Login" in the menu bar menu, through SMAppService (macOS 13+).
// It registers the bundle that is running, so it can only be turned on for an
// installed copy (in /Applications or ~/Applications): one registered from
// build/ would stop working as soon as build.sh replaces that bundle.

import Cocoa
import ServiceManagement

@MainActor
enum LoginItem {
    enum State: Equatable {
        case off
        case on
        /// Registered, but not allowed to run at login: waiting for the
        /// user's approval, or turned off in System Settings > General >
        /// Login Items (which reports the same status).
        case needsApproval

        /// The menu item's check mark: a dash while it can't run at login.
        var controlState: NSControl.StateValue {
            switch self {
            case .off: return .off
            case .on: return .on
            case .needsApproval: return .mixed
            }
        }
    }

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

    static var state: State {
        guard #available(macOS 13.0, *) else { return .off }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    /// Whether the menu item is enabled: turning it on needs an installed
    /// copy; turning it off or approving it works from anywhere.
    nonisolated static func canToggle(state: State, installed: Bool) -> Bool {
        installed || state != .off
    }

    /// The menu item's tooltip: why it is dimmed or shows a dash.
    nonisolated static func toolTip(state: State, installed: Bool) -> String? {
        switch state {
        case .needsApproval:
            return "Not allowed to run at login: turn Launcher on in System Settings > General > Login Items."
        case .off where !installed:
            return "Only for a copy in /Applications or ~/Applications."
        default:
            return nil
        }
    }

    /// On turns it off, off turns it on. Waiting for approval opens System
    /// Settings on Login Items, where the user allows it (unregistering would
    /// take a second click to get back). Errors are shown in an alert.
    static func toggle() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            switch state {
            case .on:
                try service.unregister()
            case .needsApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .off:
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModalInFront()
        }
    }
}
