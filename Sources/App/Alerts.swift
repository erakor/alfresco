// Alerts.swift
//
// The app runs as an accessory with non-activating panels, so an alert has to
// bring the app forward first or it opens behind the frontmost app.

import Cocoa

extension NSAlert {
    /// Activates the app, then runs the alert.
    @MainActor
    @discardableResult
    func runModalInFront() -> NSApplication.ModalResponse {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        return runModal()
    }
}
