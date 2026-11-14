// TransitStatusItem.swift
//
// The transit menu bar item: a tram whose menu shows the departure board
// for Config.transitStation and the station's service alerts. Trains are
// fetched when the menu opens (TransitProvider.refreshIfStale, shared with
// the launcher's `/transit`) and redrawn every 10 s while it stays open.
// Alerts are also checked every Config.transitAlertCheckInterval while the
// screens are awake, so the icon can show a dot during an incident.

import Cocoa

@MainActor
final class TransitStatusItem: NSObject, NSMenuDelegate {
    private static let redrawInterval: TimeInterval = 10

    private let provider: TransitProvider
    private let openLauncher: @MainActor () -> Void
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let boardView = TransitMenuView(frame: .zero)
    private let boardItem = NSMenuItem()
    private var redrawTimer: Timer?
    private var alertTimer: Timer?
    private var isMenuOpen = false
    private var screensAsleep = false
    /// Whether the icon shows the dot, so the image is only set on change.
    private var showsAlert: Bool?

    #if SELFTEST
    var showsAlertForSelfTest: Bool { showsAlert ?? false }
    var toolTipForSelfTest: String? { item.button?.toolTip }
    var menuTitlesForSelfTest: [String] { menu.items.map(\.title) }
    var menuViewForSelfTest: TransitMenuView { boardView }
    var isAlertTimerRunningForSelfTest: Bool { alertTimer != nil }
    /// Opens the menu's content as opening the menu does, without tracking it.
    func openForSelfTest() { menuWillOpen(menu) }
    func closeForSelfTest() { menuDidClose(menu) }
    /// Redraws the icon and an open menu as a finished fetch does.
    func providerDidUpdateForSelfTest() { providerDidUpdate() }
    func screensDidSleepForSelfTest() { screensDidSleep() }
    func screensDidWakeForSelfTest() { screensDidWake() }
    /// Takes the item out of the menu bar and stops its timers.
    func removeForSelfTest() {
        menuDidClose(menu)
        screensDidSleep()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSStatusBar.system.removeStatusItem(item)
    }
    #endif

    /// `openLauncher` opens the launcher on `/transit`.
    init(provider: TransitProvider, openLauncher: @escaping @MainActor () -> Void) {
        self.provider = provider
        self.openLauncher = openLauncher
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        buildMenu()
        item.menu = menu
        updateIcon()
        provider.addObserver { [weak self] in self?.providerDidUpdate() }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        startAlertTimer()
        checkAlerts()
    }

    private func buildMenu() {
        menu.delegate = self
        // The menu sizes itself to the view's frame, which `show` sets.
        boardItem.view = boardView
        menu.addItem(boardItem)
        menu.addItem(.separator())
        let open = NSMenuItem(
            title: "Open \(CommandInput.typed(Config.transitKeyword)) in Launcher",
            action: #selector(openInLauncher), keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        UsageStats.shared.record(.transitMenuOpened)
        isMenuOpen = true
        provider.refreshIfStale()
        provider.refreshAlertsIfStale()
        redraw()
        startRedrawTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        // A fetch still running is kept: its answer serves the next opening
        // and the launcher.
        isMenuOpen = false
        redrawTimer?.invalidate()
        redrawTimer = nil
    }

    @objc private func openInLauncher() {
        openLauncher()
    }

    /// The board and alerts as they are now; countdowns follow the clock
    /// without a refetch, and a stale snapshot is fetched again.
    private func redraw() {
        provider.refreshIfStale()
        boardView.show(provider.state(), alerts: provider.currentAlerts(), now: Date())
    }

    private func startRedrawTimer() {
        guard redrawTimer == nil else { return }
        // .common, so it also fires while the menu is tracking.
        let timer = Timer(timeInterval: Self.redrawInterval, target: self, selector: #selector(redrawTimerFired), userInfo: nil, repeats: true)
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    @objc private func redrawTimerFired() {
        redraw()
    }

    /// A fetch ended (from here or the launcher).
    private func providerDidUpdate() {
        updateIcon()
        if isMenuOpen { redraw() }
    }

    // MARK: Alerts

    /// The dot while an incident is in effect, and a tool tip saying so.
    private func updateIcon() {
        let alerts = provider.currentAlerts()
        let incidents = alerts?.incidents ?? []
        let alert = Config.transitAlertCheckInterval != nil && !incidents.isEmpty
        if showsAlert != alert {
            item.button?.image = TransitMenuBarIcon.make(alert: alert)
            showsAlert = alert
        }
        var toolTip = "Next trains"
        if let alerts, !alerts.alerts.isEmpty {
            toolTip += " · \(alerts.summary)"
            if let first = incidents.first { toolTip += "\n\(first.header)" }
        }
        if item.button?.toolTip != toolTip { item.button?.toolTip = toolTip }
    }

    private func startAlertTimer() {
        guard alertTimer == nil, let interval = Config.transitAlertCheckInterval else { return }
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(alertTimerFired), userInfo: nil, repeats: true)
        timer.tolerance = min(60, interval / 5)
        RunLoop.main.add(timer, forMode: .common)
        alertTimer = timer
    }

    @objc private func alertTimerFired() {
        checkAlerts()
    }

    /// Fetches the alerts unless the screens are asleep, and drops the dot
    /// once the last answer is too old to trust.
    private func checkAlerts() {
        updateIcon()
        guard Config.transitAlertCheckInterval != nil, !screensAsleep else { return }
        provider.refreshAlertsIfStale()
    }

    @objc private func screensDidSleep() {
        screensAsleep = true
        alertTimer?.invalidate()
        alertTimer = nil
    }

    @objc private func screensDidWake() {
        screensAsleep = false
        startAlertTimer()
        checkAlerts()
    }
}
