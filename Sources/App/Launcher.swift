// Launcher.swift
//
// A lightweight, Spotlight-style URL launcher for macOS, with a 24-hour
// clipboard history. This file holds the app delegate and the entry point;
// the features live in the other folders under Sources/.
//
// - Runs as an accessory agent (no Dock icon). A small menu bar icon offers
//   "Open", "Clipboard History", "Edit Workflows…" and "Quit"; turn it off
//   with Config.showMenuBarIcon.
// - Workflows (keyword -> URL) live in workflows.json and are reloaded
//   automatically, so adding one needs no rebuild.
//
// Build:  ./build.sh   (or see README.md for a plain swiftc command)

import Cocoa

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let workflowStore = WorkflowStore()
    private var launcher: LauncherController?
    private var clipboardStore: ClipboardStore?
    private var clipboardMonitor: ClipboardMonitor?
    private var clipboardPanel: ClipboardController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launcher = LauncherController(store: workflowStore)
        self.launcher = launcher

        let store = ClipboardStore()
        let monitor = ClipboardMonitor(store: store)
        let clipboardPanel = ClipboardController(store: store, monitor: monitor)
        clipboardStore = store
        clipboardMonitor = monitor
        self.clipboardPanel = clipboardPanel
        monitor.start()

        if Config.showMenuBarIcon {
            setUpStatusItem()
        }

        let manager = HotKeyManager()
        hotKeyManager = manager

        var failed: [HotKey] = []
        if !manager.register(Config.hotKey, action: { [weak launcher] in launcher?.toggle() }) {
            failed.append(Config.hotKey)
        }
        if !manager.register(Config.clipboardHotKey, action: { [weak clipboardPanel] in clipboardPanel?.toggle() }) {
            failed.append(Config.clipboardHotKey)
        }
        if !failed.isEmpty {
            showHotKeyError(failed)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardStore?.saveNow()
        UsageStats.shared.saveNow()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Launcher")

        let menu = NSMenu()
        menu.addItem(menuItem("Open Launcher (\(Config.hotKey.display))", #selector(openLauncher)))
        menu.addItem(menuItem("Clipboard History (\(Config.clipboardHotKey.display))", #selector(openClipboardHistory)))
        menu.addItem(menuItem("Clear Clipboard History", #selector(clearClipboardHistory)))
        menu.addItem(.separator())
        let workflows = NSMenuItem(title: "Workflows", action: nil, keyEquivalent: "")
        let workflowsMenu = NSMenu(title: "Workflows")
        workflowsMenu.delegate = self
        workflows.submenu = workflowsMenu
        menu.addItem(workflows)
        menu.addItem(menuItem("Edit Workflows…", #selector(editWorkflows)))
        menu.addItem(menuItem("Show Workflows in Finder", #selector(revealWorkflows)))
        if Config.usageTracking {
            menu.addItem(menuItem("Usage…", #selector(showUsage)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openLauncher() {
        launcher?.show()
    }

    @objc private func openClipboardHistory() {
        clipboardPanel?.show()
    }

    @objc private func clearClipboardHistory() {
        clipboardStore?.clear()
    }

    // MARK: NSMenuDelegate

    /// Rebuilds the Workflows submenu each time it opens, so it always
    /// matches workflows.json.
    func menuNeedsUpdate(_ menu: NSMenu) {
        workflowStore.reloadIfNeeded()
        menu.removeAllItems()

        let workflows = workflowStore.current.workflows
        if workflows.isEmpty {
            let empty = NSMenuItem(title: "No workflows yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for workflow in workflows {
            let item = NSMenuItem(
                title: "\(workflow.keywords.joined(separator: ", "))  \(workflow.title)",
                action: #selector(startWorkflow(_:)),
                keyEquivalent: ""
            )
            item.target = self
            // What to type: "pr " for a workflow that needs an argument,
            // the bare keyword otherwise.
            item.representedObject = workflow.keywords.first.map { workflow.takesArgument ? $0 + " " : $0 }
            if let help = workflow.help {
                if #available(macOS 14.4, *) {
                    item.subtitle = help
                } else {
                    item.toolTip = help
                }
            }
            menu.addItem(item)
        }
    }

    /// Opens the launcher with the workflow's keyword already typed.
    @objc private func startWorkflow(_ sender: NSMenuItem) {
        guard let prefill = sender.representedObject as? String else { return }
        launcher?.show(prefill: prefill)
    }

    /// Opens workflows.json in the default editor for JSON files. Changes are
    /// picked up the next time the launcher opens.
    @objc private func editWorkflows() {
        workflowStore.ensureFileExists()
        NSWorkspace.shared.open(workflowStore.fileURL)
    }

    @objc private func revealWorkflows() {
        workflowStore.ensureFileExists()
        NSWorkspace.shared.activateFileViewerSelecting([workflowStore.fileURL])
    }

    /// The last 30 days of UsageStats, with a button to the file itself.
    @objc private func showUsage() {
        let stats = UsageStats.shared
        stats.saveNow()
        let alert = NSAlert()
        alert.messageText = "Usage, last 30 days"
        alert.informativeText = stats.summary(days: 30)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show File in Finder")
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if alert.runModal() == .alertSecondButtonReturn {
            if FileManager.default.fileExists(atPath: stats.fileURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([stats.fileURL])
            } else {
                NSWorkspace.shared.open(stats.fileURL.deletingLastPathComponent())
            }
        }
    }

    private func showHotKeyError(_ hotKeys: [HotKey]) {
        let names = hotKeys.map(\.display).joined(separator: " and ")
        let alert = NSAlert()
        alert.messageText = "Could not register \(names)"
        alert.informativeText = """
            Another app may already use \(hotKeys.count == 1 ? "this shortcut" : "these shortcuts"), \
            or macOS rejected \(hotKeys.count == 1 ? "it" : "them"). Change Config.hotKey or \
            Config.clipboardHotKey in Sources/App/Config.swift and rebuild.
            """
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        alert.runModal()
    }
}

@main
enum LauncherApp {
    @MainActor
    static func main() {
        // Two copies (say ./Launcher and build/Launcher.app) would fight over
        // the hotkeys and overwrite each other's clipboard history, so a
        // second copy quits. exit(0) also keeps a LaunchAgent's KeepAlive
        // from restarting it.
        guard acquireSingleInstanceLock() else {
            FileHandle.standardError.write(Data("Launcher is already running; quit it first.\n".utf8))
            NSLog("Launcher: another copy is already running, exiting")
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

extension LauncherApp {
    /// Takes an exclusive lock on a file in the shared support folder and holds
    /// it until the process exits (the descriptor is never closed; the system
    /// releases the lock on exit, including a crash). False if another copy
    /// holds it.
    @MainActor
    static func acquireSingleInstanceLock() -> Bool {
        let directory = ClipboardStore.directory
        try? ClipImageFile.createPrivateDirectory(directory)
        let path = directory.appendingPathComponent("launcher.lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        // If the lock file can't be opened, run anyway rather than not at all.
        guard descriptor >= 0 else { return true }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        close(descriptor)
        return false
    }
}
