// PomodoroStatusItem.swift
//
// The menu bar countdown. Its own status item, shown only while a session
// or break is under way (whatever Config.showMenuBarIcon says), with a menu
// to pause, skip or stop.

import Cocoa

@MainActor
final class PomodoroStatusItem: NSObject {
    private let timer: PomodoroTimer
    private var item: NSStatusItem?
    /// Built once and handed to each new status item: a menu item can only
    /// belong to one menu.
    let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let skipItem = NSMenuItem(title: "Skip", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop", action: nil, keyEquivalent: "")
    /// The phase whose icon the button shows, so it is only set on change.
    private var shownPhase: PomodoroPhase?
    /// The SF Symbol the button shows.
    private(set) var symbolName: String?

    // What the menu bar shows, for the self-test.
    var isShown: Bool { item != nil }
    var buttonTitle: String? { item?.button?.title }
    var appearsDisabled: Bool { item?.button?.appearsDisabled ?? false }
    var menuTitles: [String] { menu.items.map(\.title) }

    init(timer: PomodoroTimer) {
        self.timer = timer
        super.init()
        buildMenu()
        update()
    }

    /// Shows, refreshes or removes the item to match the timer. Called on
    /// every timer change, including each second while it runs.
    func update() {
        guard let phase = timer.state.phase, let remaining = timer.remaining() else {
            if let item {
                NSStatusBar.system.removeStatusItem(item)
                self.item = nil
                shownPhase = nil
                symbolName = nil
            }
            return
        }

        let item = self.item ?? makeStatusItem()
        guard let button = item.button else { return }
        if shownPhase != phase {
            let symbol = phase.isBreak ? "cup.and.saucer" : "timer"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: phase.name)
            button.imagePosition = .imageLeading
            shownPhase = phase
            symbolName = symbol
        }
        let paused = timer.state.isPaused
        button.title = " " + PomodoroTimer.format(remaining)
        button.appearsDisabled = paused
        button.toolTip = timer.summary

        statusLine.title = timer.summary
        pauseItem.title = paused ? "Resume" : "Pause"
        skipItem.title = phase == .focus ? "Skip to Break" : "End Break"
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Digits of equal width, so the item doesn't wobble as it counts down.
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.menu = menu
        self.item = item
        return item
    }

    private func buildMenu() {
        // No action, so the menu shows it disabled: it's a label.
        menu.addItem(statusLine)
        menu.addItem(.separator())
        for (menuItem, action) in [
            (pauseItem, #selector(togglePause)),
            (skipItem, #selector(skip)),
            (stopItem, #selector(stop)),
        ] {
            menuItem.target = self
            menuItem.action = action
            menu.addItem(menuItem)
        }
    }

    @objc private func togglePause() {
        if timer.state.isPaused {
            timer.resume()
        } else {
            timer.pause()
        }
    }

    @objc private func skip() {
        timer.skip()
    }

    @objc private func stop() {
        timer.stop()
    }
}
