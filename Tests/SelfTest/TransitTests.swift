// TransitTests.swift
//
// `/transit`: the GTFS-Realtime reader finds the trains due at the
// station's platforms in a feed built here byte by byte (unknown fields and
// the MTA's extensions skipped, skipped stops and deleted entities left
// out, damaged data refused), the board sorts, limits and counts down, and
// the real launcher shows it while the input runs the transit workflow.
// Never fetches: the self-test build's TransitProvider doesn't.

import Foundation

@MainActor
enum TransitTests {
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        SelfTest.check("transit: \(name)", condition, detail())
    }

    private static let now = Date(timeIntervalSince1970: 1_794_000_000)
    private static let stopIDs: Set<String> = ["A32", "D20"]

    static func run() {
        decoding()
        damaged()
        board()
        launcher()
    }

    // MARK: Protobuf writing (just enough for a feed)

    private static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
        return bytes
    }

    private static func field(_ number: Int, varint value: UInt64) -> [UInt8] {
        varint(UInt64(number << 3)) + varint(value)
    }

    private static func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    private static func field(_ number: Int, string: String) -> [UInt8] {
        field(number, bytes: Array(string.utf8))
    }

    /// A StopTimeUpdate `seconds` from `now`; `arrivalOnly` leaves out the
    /// departure, `relationship` 1 is skipped.
    private static func stop(
        _ id: String, in seconds: Int, arrivalOnly: Bool = false, relationship: UInt64? = nil
    ) -> [UInt8] {
        let time = UInt64(Int(now.timeIntervalSince1970) + seconds)
        var bytes = field(1, varint: 7) // stop_sequence
        bytes += field(2, bytes: field(1, varint: 0) + field(2, varint: time - (arrivalOnly ? 0 : 30)))
        if !arrivalOnly { bytes += field(3, bytes: field(2, varint: time)) }
        bytes += field(4, string: id)
        if let relationship { bytes += field(5, varint: relationship) }
        // An unknown fixed32 field and the MTA's extension (1001).
        bytes += varint(UInt64(9 << 3 | 5)) + [1, 2, 3, 4]
        bytes += field(1001, bytes: field(1, string: "track 2"))
        return bytes
    }

    private static func tripUpdate(route: String, stops: [[UInt8]]) -> [UInt8] {
        // The descriptor with an MTA extension and a fixed64 field to skip.
        let descriptor = field(1, string: "trip-\(route)") + field(3, string: "20261109")
            + varint(UInt64(8 << 3 | 1)) + [0, 0, 0, 0, 0, 0, 0, 0]
            + field(5, string: route) + field(1001, bytes: field(1, string: "1F 0930 WTC/207"))
        return field(1, bytes: descriptor) + stops.flatMap { field(2, bytes: $0) } + field(4, varint: 1_794_000_000)
    }

    private static func entity(_ id: String, tripUpdate: [UInt8], deleted: Bool = false) -> [UInt8] {
        field(1, string: id) + (deleted ? field(2, varint: 1) : []) + field(3, bytes: tripUpdate)
    }

    private static func feed(_ entities: [[UInt8]]) -> Data {
        let header = field(1, string: "2.0") + field(2, varint: 0) + field(3, varint: 1_794_000_000)
        // A vehicle position entity, which carries no trip update.
        let vehicle = field(1, string: "v1") + field(4, bytes: field(1, bytes: field(5, string: "A")))
        return Data(field(1, bytes: header) + entities.flatMap { field(2, bytes: $0) } + field(2, bytes: vehicle))
    }

    private static var sampleFeed: Data {
        feed([
            entity("1", tripUpdate: tripUpdate(route: "A", stops: [
                stop("A31N", in: 60), stop("A32N", in: 240), stop("A33N", in: 400),
            ])),
            entity("2", tripUpdate: tripUpdate(route: "E", stops: [stop("A32S", in: 30, arrivalOnly: true)])),
            entity("3", tripUpdate: tripUpdate(route: "FX", stops: [stop("D20S", in: 600)])),
            entity("4", tripUpdate: tripUpdate(route: "C", stops: [stop("A32N", in: 120, relationship: 1)])),
            entity("5", tripUpdate: tripUpdate(route: "D", stops: [stop("D20N", in: 90)]), deleted: true),
            entity("6", tripUpdate: tripUpdate(route: "M", stops: [stop("D20", in: 90), stop("D20X", in: 90)])),
        ])
    }

    // MARK: Checks

    private static func decoding() {
        let times: [GTFSRealtime.StopTime]
        do {
            times = try GTFSRealtime.stopTimes(in: sampleFeed, stopIDs: stopIDs)
        } catch {
            check("the sample feed decodes", false, "\(error)")
            return
        }
        let summary = times.map { "\($0.route) \($0.direction) \(Int($0.time.timeIntervalSince(now)))" }
        check("only the station's platforms, skipped and deleted left out",
              summary == ["A north 240", "E south 30", "FX south 600"], summary.description)
        check("the departure time is preferred, else the arrival",
              times.first?.time == now.addingTimeInterval(240))
        check("an empty feed has no trains", (try? GTFSRealtime.stopTimes(in: Data(), stopIDs: stopIDs)) == [])
        check("A32N is uptown", GTFSRealtime.direction(of: "A32N", stopIDs: stopIDs) == .north)
        check("D20S is downtown", GTFSRealtime.direction(of: "D20S", stopIDs: stopIDs) == .south)
        check("another station isn't", GTFSRealtime.direction(of: "A31N", stopIDs: stopIDs) == nil)
        check("a parent ID isn't a platform", GTFSRealtime.direction(of: "A32", stopIDs: stopIDs) == nil)
    }

    private static func damaged() {
        let bytes = [UInt8](sampleFeed)
        let cut = Data(bytes.prefix(bytes.count - 5))
        check("a truncated feed is refused", (try? GTFSRealtime.stopTimes(in: cut, stopIDs: stopIDs)) == nil)
        let tooLong = Data(field(2, bytes: []).dropLast() + varint(1_000))
        check("a length past the end is refused", (try? GTFSRealtime.stopTimes(in: tooLong, stopIDs: stopIDs)) == nil)
        let endless = Data([0x10] + [UInt8](repeating: 0xFF, count: 12))
        check("an endless varint is refused", (try? GTFSRealtime.stopTimes(in: endless, stopIDs: stopIDs)) == nil)
        let group = Data(varint(UInt64(2 << 3 | 3)))
        check("a group is refused", (try? GTFSRealtime.stopTimes(in: group, stopIDs: stopIDs)) == nil)
        let fieldZero = Data(field(0, varint: 1))
        check("field 0 is refused", (try? GTFSRealtime.stopTimes(in: fieldZero, stopIDs: stopIDs)) == nil)
    }

    private static func snapshot() -> TransitSnapshot {
        func time(_ route: String, _ direction: TransitDirection, _ seconds: TimeInterval) -> GTFSRealtime.StopTime {
            GTFSRealtime.StopTime(route: route, direction: direction, time: now.addingTimeInterval(seconds))
        }
        return TransitSnapshot(
            stopTimes: [
                time("C", .north, 600), time("A", .north, 45), time("E", .north, -10), time("A", .north, -60),
                time("B", .north, 300), time("D", .north, 900), time("FX", .north, 61),
                time("F", .north, 61), // the same train in another feed
                time("M", .south, 125),
            ],
            fetchedAt: now.addingTimeInterval(-25),
            missingFeeds: 0
        )
    }

    private static func board() {
        let board = TransitBoard.make(from: snapshot(), now: now, limit: 4)
        let north = board.north.map { "\($0.route) \(TransitBoard.countdown(to: $0.time, now: now))" }
        check("soonest first, gone ones dropped, duplicates once, at most the limit",
              north == ["E now", "A now", "F 1 min", "B 5 min"], north.description)
        check("the other way has its own list", board.south.map(\.route) == ["M"])
        check("counts down in whole minutes", TransitBoard.countdown(to: now.addingTimeInterval(179), now: now) == "2 min")
        check("the snapshot's age", TransitBoard.age(of: now.addingTimeInterval(-25), now: now) == "25 s ago")
        check("a fresh one", TransitBoard.age(of: now, now: now) == "just now")
        check("an older one", TransitBoard.age(of: now.addingTimeInterval(-130), now: now) == "2 min ago")
        check("express and shuttle bullets",
              ["FX", "6X", "GS", "H", "A", "SI"].map(TransitBoard.displayRoute) == ["F", "6", "S", "S", "A", "SIR"])
        check("yellow lines have dark letters", TransitBoard.color(of: "Q").darkText && !TransitBoard.color(of: "A").darkText)
    }

    private static let json = #"""
    {"workflows": [
      {"keywords": ["transit", "metro", "bus"], "title": "Trains", "url": "https://example.com/station"},
      {"keywords": ["busy"], "title": "Not the board", "url": "https://example.com/busy"},
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
        for keyword in ["/transit", "/metro", "/bus", "/bus "] {
            controller.typeForSelfTest(keyword)
            check("\"\(keyword)\" shows the board", controller.showsTransitForSelfTest)
        }
        check("loading until a snapshot arrives", controller.transitBoardForSelfTest == nil)
        controller.setTransitSnapshotForSelfTest(
            TransitSnapshot(
                stopTimes: [GTFSRealtime.StopTime(route: "A", direction: .north, time: Date().addingTimeInterval(200))],
                fetchedAt: Date(), missingFeeds: 0
            )
        )
        check("the snapshot's trains are on the board", controller.transitBoardForSelfTest?.north.map(\.route) == ["A"])
        controller.setTransitSnapshotForSelfTest(
            TransitSnapshot(stopTimes: [], fetchedAt: Date().addingTimeInterval(-TransitProvider.snapshotLifetime - 1), missingFeeds: 0)
        )
        check("a snapshot past its lifetime isn't shown", controller.transitBoardForSelfTest == nil)
        for other in ["/busy", "/zz", "bus", "/", ""] {
            controller.typeForSelfTest(other)
            check("\"\(other)\" doesn't show it", !controller.showsTransitForSelfTest)
        }
    }
}
