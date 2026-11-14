// TransitTests.swift
//
// `/transit`: an answer of the transit service decodes into a snapshot,
// the board sorts, limits and counts down, and the real launcher shows it
// while the input runs the transit workflow. The station's alerts decode,
// and the menu bar item shows the board, lists the alerts and marks its
// icon during an incident. Never fetches: the self-test build has no
// transit service (Config.transitService).

import AppKit

@MainActor
enum TransitTests {
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        SelfTest.check("transit: \(name)", condition, detail())
    }

    private static let now = Date(timeIntervalSince1970: 1_794_000_000)

    static func run() {
        decoding()
        board()
        launcher()
        alertsDecoding()
        icon()
        statusItem()
    }

    /// An answer of the transit service's /subway/arrivals, with fields the
    /// board doesn't read.
    private static let answer = #"""
    {"stop": {"id": "A32+D20", "name": "W 4 St-Wash Sq", "stops": ["A32", "D20"]},
     "updatedAt": 1793999990,
     "groups": [
       {"route": "A", "name": "A", "color": "#0062CF", "textColor": "#FFFFFF", "direction": "N",
        "headsign": "Inwood-207 St", "arrivals": [
          {"time": 1794000240, "headsign": "Inwood-207 St", "tripId": "a1"},
          {"time": 1794000600, "headsign": "Inwood-207 St", "tripId": "a2"}]},
       {"route": "FX", "name": "F", "color": "#EB6800", "textColor": "#FFFFFF", "direction": "S",
        "headsign": "Coney Island-Stillwell Av", "arrivals": [
          {"time": 1794000030, "headsign": "Coney Island-Stillwell Av", "tripId": "f1"}]},
       {"route": "Q", "name": "Q", "color": "#F6BC26", "textColor": "#000000", "direction": "S",
        "headsign": "Coney Island-Stillwell Av", "arrivals": []}
     ],
     "unavailableFeeds": ["gtfs-bdfm"]}
    """#

    private static func decoding() {
        guard let snapshot = TransitLoader.snapshot(from: Data(answer.utf8), fetchedAt: now) else {
            check("the service's answer decodes", false)
            return
        }
        check("the station's name", snapshot.stationName == "W 4 St-Wash Sq")
        let summary = snapshot.departures.map { "\($0.route) \($0.direction.rawValue) \(Int($0.time.timeIntervalSince(now)))" }
        check("every train, with the route's rider-facing name",
              summary == ["A N 240", "A N 600", "F S 30"], summary.description)
        check("line colors", snapshot.departures.first?.color == 0x0062CF && snapshot.departures.first?.textColor == 0xFFFFFF)
        check("the age is the feed's", snapshot.updatedAt == now.addingTimeInterval(-10))
        check("failed feeds are noted", snapshot.someLinesMissing)
        let minimal = #"{"stop": {"name": "X"}, "updatedAt": null, "groups": []}"#
        let empty = TransitLoader.snapshot(from: Data(minimal.utf8), fetchedAt: now)
        check("no trains and no feed time", empty?.departures == [] && empty?.updatedAt == now && empty?.someLinesMissing == false)
        check("an error body isn't an answer", TransitLoader.snapshot(from: Data(#"{"error": "unknown stop"}"#.utf8), fetchedAt: now) == nil)
        check("a bad color falls back", TransitLoader.rgb("blue") == nil && TransitLoader.rgb("#00FF00") == 0x00FF00)

        let service = TransitService(baseURL: URL(string: "https://transit.example.com")!, token: "t")
        let url = TransitLoader.url(for: "A32+D20", limit: 30, service: service)?.absoluteString
        check("the station's + is encoded and the limit capped",
              url == "https://transit.example.com/subway/arrivals?stop=A32%2BD20&limit=10", url ?? "nil")
    }

    private static func departure(_ route: String, _ direction: TransitDirection, _ seconds: TimeInterval) -> TransitDeparture {
        TransitDeparture(route: route, color: 0, textColor: 0, direction: direction, time: now.addingTimeInterval(seconds))
    }

    private static func snapshot(_ departures: [TransitDeparture], fetchedAt: Date) -> TransitSnapshot {
        TransitSnapshot(stationName: "W 4 St", departures: departures, updatedAt: fetchedAt, fetchedAt: fetchedAt, someLinesMissing: false)
    }

    private static func board() {
        let trains = [
            departure("C", .north, 600), departure("A", .north, 45), departure("E", .north, -10),
            departure("A", .north, -60), departure("B", .north, 300), departure("D", .north, 900),
            departure("F", .north, 61), departure("M", .south, 125),
        ]
        let board = TransitBoard.make(from: snapshot(trains, fetchedAt: now), now: now, limit: 4)
        let north = board.north.map { "\($0.route) \(TransitBoard.countdown(to: $0.time, now: now))" }
        check("soonest first, gone ones dropped, at most the limit",
              north == ["E now", "A now", "F 1 min", "B 5 min"], north.description)
        check("the other way has its own list", board.south.map(\.route) == ["M"])
        check("counts down in whole minutes", TransitBoard.countdown(to: now.addingTimeInterval(179), now: now) == "2 min")
        check("the snapshot's age", TransitBoard.age(of: now.addingTimeInterval(-25), now: now) == "25 s ago")
        check("a fresh one", TransitBoard.age(of: now, now: now) == "just now")
        check("an older one", TransitBoard.age(of: now.addingTimeInterval(-130), now: now) == "2 min ago")
    }

    private static let json = #"""
    {"workflows": [
      {"keywords": ["transit", "metro"], "title": "Trains", "url": "https://example.com/station"},
      {"keywords": ["bus"], "title": "Not the board", "url": "https://example.com/bus"},
      {"keywords": ["zz"], "title": "Sleep", "url": "alfresco://system/sleep"}
    ]}
    """#

    private static func launcher() {
        guard Config.transitStation != nil, Config.commandPrefix == "/" else {
            check("Config.transitStation is off or the prefix isn't /, nothing to test", true)
            return
        }
        let url = SelfTest.scratchFile("transit-workflows")
        do {
            try Data(json.utf8).write(to: url)
        } catch {
            check("the test workflows file is written", false, error.localizedDescription)
            return
        }
        let provider = TransitProvider()
        let controller = LauncherController(
            store: WorkflowStore(fileURL: url, createsMissingFile: false), transit: provider,
            internalURLHandler: { _ in true }
        )
        for keyword in ["/transit", "/metro", "/metro "] {
            controller.typeForSelfTest(keyword)
            check("\"\(keyword)\" shows the board", controller.showsTransitForSelfTest)
        }
        check("without a service, no trains", controller.transitBoardForSelfTest == nil)
        render(controller, as: "transit-setup")
        let soon = TransitDeparture(route: "A", color: 0, textColor: 0, direction: .north, time: Date().addingTimeInterval(200))
        controller.setTransitSnapshotForSelfTest(snapshot([soon], fetchedAt: Date()))
        check("the snapshot's trains are on the board", controller.transitBoardForSelfTest?.north.map(\.route) == ["A"])
        controller.setTransitSnapshotForSelfTest(sampleBoard())
        render(controller, as: "transit-board")
        controller.setTransitSnapshotForSelfTest(
            snapshot([], fetchedAt: Date().addingTimeInterval(-TransitProvider.snapshotLifetime - 1))
        )
        check("a snapshot past its lifetime isn't shown", controller.transitBoardForSelfTest == nil)
        // The menu bar item shares the provider: what it fetched is on the board.
        provider.setSnapshotForSelfTest(snapshot([soon], fetchedAt: Date()))
        controller.typeForSelfTest("/transit")
        check("the board shows the shared provider's trains", controller.transitBoardForSelfTest?.north.map(\.route) == ["A"])
        for other in ["/bus", "/zz", "metro", "/", ""] {
            controller.typeForSelfTest(other)
            check("\"\(other)\" doesn't show it", !controller.showsTransitForSelfTest)
        }
    }

    // MARK: Alerts

    /// An answer of the service's /subway/alerts?stop=, with fields the menu
    /// doesn't read.
    private static let alertsAnswer = #"""
    {"stop": {"id": "A32+D20", "name": "W 4 St-Wash Sq", "stops": ["A32", "D20"]},
     "updatedAt": 1793999990,
     "alerts": [
       {"id": "lmm:alert:1", "planned": false, "category": "Delays", "priority": 26,
        "header": "  Downtown [A][C] trains are running with delays.\n", "description": "",
        "routes": [{"id": "A", "name": "A", "color": "#0062CF", "textColor": "#FFFFFF"},
                   {"id": "C", "name": "C", "color": "bad", "textColor": "#FFFFFF"}],
        "stops": [], "start": 1793999000, "end": null},
       {"id": "lmm:planned_work:2", "planned": true, "category": null, "priority": null,
        "header": "No [F] trains between W 4 St and Jay St.", "description": "Take the [A].",
        "routes": [], "stops": [{"id": "D20", "name": "W 4 St", "direction": "S"}],
        "start": 1793990000, "end": 1794010000}
     ]}
    """#

    private static func alertsDecoding() {
        guard let alerts = TransitAlertsLoader.alerts(from: Data(alertsAnswer.utf8), fetchedAt: now) else {
            check("alerts: the service's answer decodes", false)
            return
        }
        check("alerts: both, in the service's order", alerts.alerts.map(\.id) == ["lmm:alert:1", "lmm:planned_work:2"])
        check("alerts: the header is trimmed", alerts.alerts.first?.header == "Downtown [A][C] trains are running with delays.")
        check("alerts: routes and colors, a bad one falls back",
              alerts.alerts.first?.routes == [
                  TransitRoute(name: "A", color: 0x0062CF, textColor: 0xFFFFFF),
                  TransitRoute(name: "C", color: 0x808183, textColor: 0xFFFFFF),
              ])
        check("alerts: only the incident marks the icon", alerts.incidents.map(\.id) == ["lmm:alert:1"])
        check("alerts: the summary", alerts.summary == "1 service alert, 1 planned change", alerts.summary)
        check("alerts: none", TransitAlerts(alerts: [], fetchedAt: now).summary == "No service alerts")
        check("alerts: a status, else the kind",
              alerts.alerts.map { TransitMenuView.categoryText(of: $0) } == ["Delays", "Planned work"])
        check("alerts: an error body isn't an answer",
              TransitAlertsLoader.alerts(from: Data(#"{"error": "unknown stop"}"#.utf8), fetchedAt: now) == nil)

        let service = TransitService(baseURL: URL(string: "https://transit.example.com")!, token: "t")
        let url = TransitAlertsLoader.url(for: "A32+D20", service: service)?.absoluteString
        check("alerts: the station's + is encoded",
              url == "https://transit.example.com/subway/alerts?stop=A32%2BD20", url ?? "nil")
    }

    private static func alert(_ id: String, planned: Bool, category: String? = nil) -> TransitAlert {
        TransitAlert(
            id: id, planned: planned, category: category,
            header: "Trains are running with delays while crews make repairs near this station.",
            routes: [TransitRoute(name: "A", color: 0x0062CF, textColor: 0xFFFFFF)]
        )
    }

    // MARK: Menu bar item

    private static func icon() {
        for alert in [false, true] {
            let image = TransitMenuBarIcon.make(alert: alert)
            let name = alert ? "with the dot" : "plain"
            check("icon \(name): template image", image.isTemplate)
            check("icon \(name): 18 pt square", image.size == TransitMenuBarIcon.size)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                check("icon \(name): bitmap for drawing", false)
                continue
            }
            bitmap.size = image.size
            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                check("icon \(name): bitmap for drawing", false)
                continue
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()

            // Points from the top left, as the icon draws them.
            func alpha(_ x: CGFloat, _ y: CGFloat) -> Double {
                Double(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.alphaComponent ?? -1)
            }
            var drawn = 0
            for x in 0..<36 {
                for y in 0..<36 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    drawn += 1
                }
            }
            check("icon \(name): the tram is drawn", drawn > 60, "\(drawn) pixels")
            let center = TransitMenuBarIcon.badgeCenter
            if alert {
                check("icon with the dot: the dot", alpha(center.x, center.y) > 0.9, "alpha \(alpha(center.x, center.y))")
                let ring = TransitMenuBarIcon.badgeRadius + TransitMenuBarIcon.badgeGap / 2
                let left = alpha(center.x - ring, center.y)
                let below = alpha(center.x, center.y + ring)
                check("icon with the dot: a clear ring around it", left < 0.1 && below < 0.1, "alpha \(left), \(below)")
            }
        }
    }

    private static func statusItem() {
        let provider = TransitProvider()
        let item = TransitStatusItem(provider: provider) {}
        defer { item.removeForSelfTest() }

        check("menu bar: no dot before any alert", !item.showsAlertForSelfTest)
        check("menu bar: tool tip", item.toolTipForSelfTest == "Next trains", item.toolTipForSelfTest ?? "nil")
        check("menu bar: alerts are checked in the background",
              item.isAlertTimerRunningForSelfTest == (Config.transitAlertCheckInterval != nil))
        let openTitle = "Open \(CommandInput.typed(Config.transitKeyword)) in Launcher"
        check("menu bar: the menu", item.menuTitlesForSelfTest.contains(openTitle), item.menuTitlesForSelfTest.description)

        let view = item.menuViewForSelfTest
        item.openForSelfTest()
        check("menu bar: without a service, no trains", view.boardForSelfTest == nil)
        check("menu bar: no alerts section before an answer", view.alertsTitleForSelfTest == nil)
        check("menu bar: a short board while there is only a status", view.frame.height < TransitView.height)
        render(view, as: "transit-menu-setup")

        provider.setSnapshotForSelfTest(sampleBoard())
        provider.setAlertsForSelfTest(TransitAlerts(
            alerts: [alert("1", planned: false, category: "Delays"), alert("2", planned: true, category: "Planned - Stops Skipped")],
            fetchedAt: Date()
        ))
        item.providerDidUpdateForSelfTest()
        check("menu bar: the board's trains", view.boardForSelfTest?.north.first?.route == "A")
        check("menu bar: the alerts", view.alertRowsForSelfTest == ["Delays", "Planned - Stops Skipped"],
              view.alertRowsForSelfTest.description)
        check("menu bar: the alerts' title", view.alertsTitleForSelfTest == "1 SERVICE ALERT, 1 PLANNED CHANGE",
              view.alertsTitleForSelfTest ?? "nil")
        check("menu bar: the board and the alerts fit", view.frame.height > TransitView.height + 60, "\(view.frame.height)")
        let expectsDot = Config.transitAlertCheckInterval != nil
        check("menu bar: an incident shows the dot", item.showsAlertForSelfTest == expectsDot)
        check("menu bar: the tool tip names it",
              item.toolTipForSelfTest?.hasPrefix("Next trains · 1 service alert, 1 planned change\n") == true,
              item.toolTipForSelfTest ?? "nil")
        render(view, as: "transit-menu")

        provider.setAlertsForSelfTest(TransitAlerts(alerts: [alert("3", planned: true)], fetchedAt: Date()))
        item.providerDidUpdateForSelfTest()
        check("menu bar: planned work alone shows no dot", !item.showsAlertForSelfTest)

        provider.setAlertsForSelfTest(TransitAlerts(
            alerts: (1...6).map { alert("\($0)", planned: false) }, fetchedAt: Date()
        ))
        item.providerDidUpdateForSelfTest()
        check("menu bar: at most four alerts listed", view.alertRowsForSelfTest.count == TransitMenuView.maxAlerts)
        check("menu bar: the rest counted", view.moreForSelfTest == "2 more alerts", view.moreForSelfTest ?? "nil")
        check("menu bar: a row without a status says what it is", view.alertRowsForSelfTest.first == "Service alert")

        provider.setAlertsForSelfTest(TransitAlerts(
            alerts: [alert("4", planned: false)],
            fetchedAt: Date().addingTimeInterval(-TransitProvider.alertsShownFor - 1)
        ))
        item.providerDidUpdateForSelfTest()
        check("menu bar: alerts too old are dropped", !item.showsAlertForSelfTest && view.alertsTitleForSelfTest == nil)

        item.screensDidSleepForSelfTest()
        check("menu bar: no checks while the screens sleep", !item.isAlertTimerRunningForSelfTest)
        item.screensDidWakeForSelfTest()
        check("menu bar: checks again on wake",
              item.isAlertTimerRunningForSelfTest == (Config.transitAlertCheckInterval != nil))
        item.closeForSelfTest()
    }

    // MARK: Renders

    /// A busy W 4 St, in the transit service's colors, for the renders.
    private static func sampleBoard() -> TransitSnapshot {
        let now = Date()
        func train(_ route: String, _ color: UInt32, _ direction: TransitDirection, _ seconds: TimeInterval) -> TransitDeparture {
            TransitDeparture(route: route, color: color, textColor: 0xFFFFFF, direction: direction, time: now.addingTimeInterval(seconds))
        }
        let blue: UInt32 = 0x0062CF, orange: UInt32 = 0xEB6800
        return TransitSnapshot(
            stationName: "W 4 St-Wash Sq",
            departures: [
                train("A", blue, .north, 20), train("F", orange, .north, 150), train("E", blue, .north, 260),
                train("D", orange, .north, 420), train("C", blue, .north, 610), train("M", orange, .north, 780),
                train("B", orange, .north, 900),
                train("E", blue, .south, 70), train("A", blue, .south, 200), train("F", orange, .south, 330),
                train("M", orange, .south, 540), train("C", blue, .south, 700), train("D", orange, .south, 850),
            ],
            updatedAt: now.addingTimeInterval(-25),
            fetchedAt: now,
            someLinesMissing: false
        )
    }

    /// Writes `view` as it lays out now to <name>-light.png and
    /// <name>-dark.png in SELFTEST_RENDER_DIR, when it is set, on a flat
    /// window background (a menu's is frosted).
    private static func render(_ view: NSView, as name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SELFTEST_RENDER_DIR"], !folder.isEmpty else { return }
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let file = URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(suffix).png")
            let previous = view.appearance
            let appearance = NSAppearance(named: appearanceName)
            view.appearance = appearance
            defer { view.appearance = previous }
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0,
                  let content = view.bitmapImageRepForCachingDisplay(in: bounds),
                  let rep = NSBitmapImageRep(
                      bitmapDataPlanes: nil, pixelsWide: content.pixelsWide, pixelsHigh: content.pixelsHigh,
                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                  )
            else {
                check("\(name) renders in \(suffix) mode", false)
                continue
            }
            view.cacheDisplay(in: bounds, to: content)
            rep.size = bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            appearance?.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                bounds.fill()
                content.draw(in: bounds)
            }
            NSGraphicsContext.restoreGraphicsState()
            do {
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    check("\(name) renders in \(suffix) mode", false)
                    continue
                }
                try png.write(to: file)
                check("\(name) renders in \(suffix) mode", true)
            } catch {
                check("\(name) renders in \(suffix) mode", false, error.localizedDescription)
            }
        }
    }

    /// Writes the launcher panel as it is now to <name>-light.png and
    /// <name>-dark.png in SELFTEST_RENDER_DIR, when it is set (CI uploads them).
    private static func render(_ controller: LauncherController, as name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SELFTEST_RENDER_DIR"], !folder.isEmpty else { return }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let file = URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(suffix).png")
            guard let png = controller.renderForSelfTest(appearance: appearance) else {
                check("\(name) renders in \(suffix) mode", false)
                continue
            }
            do {
                try png.write(to: file)
                check("\(name) renders in \(suffix) mode", true)
            } catch {
                check("\(name) renders in \(suffix) mode", false, error.localizedDescription)
            }
        }
    }
}
