// TransitAPI.swift
//
// The network side of the departure board, off the main actor: the MTA's
// GTFS-Realtime feeds for the station (one per group of lines, fetched
// side by side, no key needed) become a TransitSnapshot, the trains due at
// its platforms. TransitBoard (pure) turns a snapshot into what is shown
// at a given moment, so countdowns follow the clock without a refetch.

import Foundation

/// The trains due at the station, as fetched.
struct TransitSnapshot: Sendable, Equatable {
    let stopTimes: [GTFSRealtime.StopTime]
    let fetchedAt: Date
    /// Feeds that failed while others answered: some lines may be missing.
    let missingFeeds: Int
}

/// One train on the board.
struct TransitDeparture: Sendable, Equatable {
    /// The route as shown in its bullet ("F" for the feed's "FX").
    let route: String
    let time: Date
}

/// What the board shows at one moment: the next trains each way, soonest
/// first, without those already gone.
struct TransitBoard: Sendable, Equatable {
    let north: [TransitDeparture]
    let south: [TransitDeparture]

    /// A train counts as at the platform (shown "now") until this long
    /// after its time, then leaves the board.
    static let departedAfter: TimeInterval = 15

    static func make(from snapshot: TransitSnapshot, now: Date, limit: Int) -> TransitBoard {
        func departures(_ direction: TransitDirection) -> [TransitDeparture] {
            var seen = Set<String>()
            return snapshot.stopTimes
                .filter { $0.direction == direction && $0.time.timeIntervalSince(now) >= -departedAfter }
                .sorted { $0.time < $1.time }
                .map { TransitDeparture(route: displayRoute($0.route), time: $0.time) }
                // The same train in two feeds (a rerouted line) shows once.
                .filter { seen.insert("\($0.route) \($0.time.timeIntervalSince1970)").inserted }
                .prefix(limit)
                .map { $0 }
        }
        return TransitBoard(north: departures(.north), south: departures(.south))
    }

    /// "now" in the last minute before its time (and just after), else
    /// whole minutes, rounded down like the station countdown clocks.
    static func countdown(to time: Date, now: Date) -> String {
        let minutes = Int((time.timeIntervalSince(now) / 60).rounded(.down))
        return minutes <= 0 ? "now" : "\(minutes) min"
    }

    /// "just now", "25 s ago", "2 min ago".
    static func age(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded())
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        return "\(seconds / 60) min ago"
    }

    /// The letter on the bullet: express variants ("FX", "6X", "7X") show
    /// as their line, and the shuttles ("GS", "FS", "H") as "S".
    static func displayRoute(_ routeID: String) -> String {
        switch routeID {
        case "GS", "FS", "H": return "S"
        case "SI", "SS": return "SIR"
        default:
            if routeID.count == 2, routeID.hasSuffix("X") { return String(routeID.prefix(1)) }
            return routeID
        }
    }

    /// The line's color (sRGB, 0xRRGGBB) and whether its letter is dark,
    /// from the MTA's palette.
    static func color(of route: String) -> (rgb: UInt32, darkText: Bool) {
        switch route {
        case "A", "C", "E", "SIR": return (0x0039A6, false)
        case "B", "D", "F", "M": return (0xFF6319, false)
        case "G": return (0x6CBE45, false)
        case "J", "Z": return (0x996633, false)
        case "L": return (0xA7A9AC, false)
        case "N", "Q", "R", "W": return (0xFCCC0A, true)
        case "1", "2", "3": return (0xEE352E, false)
        case "4", "5", "6": return (0x00933C, false)
        case "7": return (0xB933AD, false)
        default: return (0x808183, false)
        }
    }
}

enum TransitError: Error, Sendable {
    case offline
    case server(Int)
    case badResponse

    var message: String {
        switch self {
        case .offline: return "Can't reach the MTA."
        case .server(let status): return "MTA: error \(status)."
        case .badResponse: return "Unreadable answer from the MTA."
        }
    }

    /// The case's name in usage.json ("transit.failed.<name>").
    var usageName: String {
        switch self {
        case .offline: return "offline"
        case .server: return "server"
        case .badResponse: return "badResponse"
        }
    }
}

enum TransitLoader {
    private static let timeout: TimeInterval = 8
    private static let baseURL = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/"
    /// A feed is a few hundred KB; anything far past that isn't one.
    private static let maxBytes = 16 * 1024 * 1024

    private enum FeedResult: Sendable {
        case stopTimes([GTFSRealtime.StopTime], bytes: Int)
        case failed(TransitError)
        case cancelled
    }

    /// Every feed of `station`, side by side. Throws TransitError when none
    /// answered, or CancellationError.
    static func load(_ station: TransitStation) async throws -> TransitSnapshot {
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval("transit.load", id: signposter.makeSignpostID())
        var outcome = Signposts.Kind.failed
        var bytes = 0
        defer { Signposts.end("transit.load", signpost, outcome, bytes: bytes) }

        let stopIDs = station.stopIDs
        let results = await withTaskGroup(of: FeedResult.self) { group in
            for feed in station.feeds {
                group.addTask { await TransitLoader.fetch(feed, stopIDs: stopIDs) }
            }
            var results: [FeedResult] = []
            for await result in group { results.append(result) }
            return results
        }

        var stopTimes: [GTFSRealtime.StopTime] = []
        var answered = 0
        var firstError: TransitError?
        for result in results {
            switch result {
            case .stopTimes(let times, let size):
                stopTimes += times
                bytes += size
                answered += 1
            case .failed(let error):
                if firstError == nil { firstError = error }
            case .cancelled:
                outcome = .cancelled
                throw CancellationError()
            }
        }
        if Task.isCancelled {
            outcome = .cancelled
            throw CancellationError()
        }
        if answered == 0, let firstError { throw firstError }
        outcome = .ok
        return TransitSnapshot(stopTimes: stopTimes, fetchedAt: Date(), missingFeeds: results.count - answered)
    }

    private static func fetch(_ feed: String, stopIDs: Set<String>) async -> FeedResult {
        let path = feed.replacingOccurrences(of: "/", with: "%2F")
        guard let url = URL(string: baseURL + path) else { return .failed(.badResponse) }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let result: (Data, URLResponse)
        do {
            result = try await HTTPSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.offline)
        }
        let data = result.0
        guard let http = result.1 as? HTTPURLResponse else { return .failed(.badResponse) }
        guard (200..<300).contains(http.statusCode) else { return .failed(.server(http.statusCode)) }
        guard data.count <= maxBytes,
              let times = try? GTFSRealtime.stopTimes(in: data, stopIDs: stopIDs)
        else { return .failed(.badResponse) }
        return .stopTimes(times, bytes: data.count)
    }
}
