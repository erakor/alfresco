// TransitTests.swift
//
// `/transit`: an answer of the transit service decodes into a snapshot,
// the board sorts, limits and counts down, and the real launcher shows it
// while the input runs the transit workflow. Never fetches: the self-test
// build has no transit service (Config.transitService).

import Foundation

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
        let controller = LauncherController(
            store: WorkflowStore(fileURL: url, createsMissingFile: false), internalURLHandler: { _ in true }
        )
        for keyword in ["/transit", "/metro", "/metro "] {
            controller.typeForSelfTest(keyword)
            check("\"\(keyword)\" shows the board", controller.showsTransitForSelfTest)
        }
        check("without a service, no trains", controller.transitBoardForSelfTest == nil)
        let soon = TransitDeparture(route: "A", color: 0, textColor: 0, direction: .north, time: Date().addingTimeInterval(200))
        controller.setTransitSnapshotForSelfTest(snapshot([soon], fetchedAt: Date()))
        check("the snapshot's trains are on the board", controller.transitBoardForSelfTest?.north.map(\.route) == ["A"])
        controller.setTransitSnapshotForSelfTest(
            snapshot([], fetchedAt: Date().addingTimeInterval(-TransitProvider.snapshotLifetime - 1))
        )
        check("a snapshot past its lifetime isn't shown", controller.transitBoardForSelfTest == nil)
        for other in ["/bus", "/zz", "metro", "/", ""] {
            controller.typeForSelfTest(other)
            check("\"\(other)\" doesn't show it", !controller.showsTransitForSelfTest)
        }
    }
}
