// TransitAPI.swift
//
// The network side of the departure board, off the main actor: one request
// to the transit service (github.com/erakor/transit), whose
// /subway/arrivals reads the MTA's real-time feeds and answers with the
// next trains at a station, names and line colors joined in. It becomes a
// TransitSnapshot; TransitBoard (pure) turns a snapshot into what is shown
// at a given moment, so countdowns follow the clock without a refetch.

import Foundation

/// Where the transit service runs and the token it expects.
struct TransitService: Sendable, Equatable {
    let baseURL: URL
    let token: String

    /// Not Authorization: the service's CDN never caches requests carrying
    /// it. Also sent with workflow previews on the service's host
    /// (PreviewRequest).
    static let tokenHeader = "X-Transit-Token"
}

/// Which way a train runs, from the MTA's platform direction: north is
/// uptown in Manhattan.
enum TransitDirection: String, Sendable, Equatable, Decodable {
    case north = "N"
    case south = "S"
}

/// One train on the board.
struct TransitDeparture: Sendable, Equatable {
    /// The route as riders know it ("F" for the "FX" express, "S" for the
    /// shuttles), from the service.
    let route: String
    /// sRGB, 0xRRGGBB.
    let color: UInt32
    let textColor: UInt32
    let direction: TransitDirection
    let time: Date
}

/// The trains due at the station, as fetched.
struct TransitSnapshot: Sendable, Equatable {
    let stationName: String
    let departures: [TransitDeparture]
    /// The oldest MTA feed used, else when the answer arrived.
    let updatedAt: Date
    /// When the answer arrived: how long it is reused and shown.
    let fetchedAt: Date
    /// Some of the station's feeds failed: some lines may be missing.
    let someLinesMissing: Bool
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
            Array(
                snapshot.departures
                    .filter { $0.direction == direction && $0.time.timeIntervalSince(now) >= -departedAfter }
                    .sorted { $0.time < $1.time }
                    .prefix(limit)
            )
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
}

enum TransitError: Error, Sendable, Equatable {
    case offline
    /// The service refused the token (401).
    case token
    case server(Int)
    case badResponse

    var message: String {
        switch self {
        case .offline: return "Can't reach the transit service."
        case .token: return "The transit service refused the token. See Sources/Transit/README.md."
        case .server(let status): return "Transit service: error \(status)."
        case .badResponse: return "Unreadable answer from the transit service."
        }
    }

    /// The case's name in usage.json ("transit.failed.<name>").
    var usageName: String {
        switch self {
        case .offline: return "offline"
        case .token: return "token"
        case .server: return "server"
        case .badResponse: return "badResponse"
        }
    }
}

enum TransitLoader {
    private static let timeout: TimeInterval = 10

    /// The /subway/arrivals answer, only the fields the board uses.
    private struct Response: Decodable {
        struct Stop: Decodable {
            let name: String
        }

        struct Group: Decodable {
            struct Arrival: Decodable {
                let time: TimeInterval
            }

            let name: String
            let color: String
            let textColor: String
            let direction: TransitDirection
            let arrivals: [Arrival]
        }

        let stop: Stop
        let updatedAt: TimeInterval?
        let groups: [Group]
        let unavailableFeeds: [String]?
    }

    /// The URL of `station`'s arrivals, `limit` trains per line and
    /// direction (the service allows 1 to 10).
    static func url(for station: String, limit: Int, service: TransitService) -> URL? {
        guard var components = URLComponents(
            url: service.baseURL.appendingPathComponent("subway/arrivals"), resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "stop", value: station),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 10))),
        ]
        // A station id joins its stops with "+", which a query reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// Decodes an answer of the service. nil when it isn't one.
    static func snapshot(from data: Data, fetchedAt: Date) -> TransitSnapshot? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let departures = response.groups.flatMap { group in
            group.arrivals.map {
                TransitDeparture(
                    route: group.name,
                    color: rgb(group.color) ?? 0x808183,
                    textColor: rgb(group.textColor) ?? 0xFFFFFF,
                    direction: group.direction,
                    time: Date(timeIntervalSince1970: $0.time)
                )
            }
        }
        return TransitSnapshot(
            stationName: response.stop.name,
            departures: departures,
            updatedAt: response.updatedAt.map(Date.init(timeIntervalSince1970:)) ?? fetchedAt,
            fetchedAt: fetchedAt,
            someLinesMissing: !(response.unavailableFeeds ?? []).isEmpty
        )
    }

    /// "#RRGGBB" as 0xRRGGBB.
    static func rgb(_ hex: String) -> UInt32? {
        guard hex.count == 7, hex.hasPrefix("#") else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }

    /// The next trains at `station`. Throws TransitError, or
    /// CancellationError.
    static func load(_ station: String, limit: Int, service: TransitService) async throws -> TransitSnapshot {
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval("transit.load", id: signposter.makeSignpostID())
        var outcome = Signposts.Kind.failed
        var bytes = 0
        defer { Signposts.end("transit.load", signpost, outcome, bytes: bytes) }

        guard let url = url(for: station, limit: limit, service: service) else { throw TransitError.badResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(service.token, forHTTPHeaderField: TransitService.tokenHeader)
        let result: (Data, URLResponse)
        do {
            result = try await HTTPSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            outcome = .cancelled
            throw CancellationError()
        } catch is CancellationError {
            outcome = .cancelled
            throw CancellationError()
        } catch {
            throw TransitError.offline
        }
        let (data, response) = result
        bytes = data.count
        if Task.isCancelled {
            outcome = .cancelled
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else { throw TransitError.badResponse }
        if http.statusCode == 401 { throw TransitError.token }
        guard (200..<300).contains(http.statusCode) else { throw TransitError.server(http.statusCode) }
        guard let snapshot = snapshot(from: data, fetchedAt: Date()) else { throw TransitError.badResponse }
        outcome = .ok
        return snapshot
    }
}
