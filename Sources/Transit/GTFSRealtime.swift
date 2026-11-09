// GTFSRealtime.swift
//
// Reads the MTA's GTFS-Realtime subway feeds, which are protocol buffers.
// The project takes no dependencies, so this is a minimal reader of the
// protobuf wire format that walks only the fields a departure board needs
// (FeedMessage.entity → FeedEntity.trip_update → TripUpdate.trip.route_id
// and TripUpdate.stop_time_update) and skips everything else, the MTA's
// own extensions included. Nonisolated and pure, so the self-test checks it.
//
// https://gtfs.org/realtime/reference/ lists the field numbers.

import Foundation

/// Which way a train runs, from the last letter of an MTA platform ID
/// ("A32N", "A32S"): north is uptown in Manhattan.
enum TransitDirection: Sendable, Equatable {
    case north
    case south
}

/// A station on the board: the MTA's parent stop IDs (stops.txt, e.g. "A32"
/// for the 8 Av platforms of W 4 St) and the feeds whose trains stop there.
struct TransitStation: Sendable {
    let name: String
    let stopIDs: Set<String>
    /// Feed paths under api-endpoint.mta.info/Dataservice/mtagtfsfeeds/,
    /// e.g. "nyct/gtfs-ace".
    let feeds: [String]
    let northLabel: String
    let southLabel: String

    init(name: String, stopIDs: [String], feeds: [String], northLabel: String = "Uptown", southLabel: String = "Downtown") {
        self.name = name
        self.stopIDs = Set(stopIDs)
        self.feeds = feeds
        self.northLabel = northLabel
        self.southLabel = southLabel
    }
}

enum GTFSRealtime {
    /// A train due at one of the station's platforms.
    struct StopTime: Sendable, Equatable {
        /// The feed's route_id ("A", "FX", "GS").
        let route: String
        let direction: TransitDirection
        /// Departure time, else arrival time.
        let time: Date
    }

    enum DecodeError: Error {
        case truncated
        case malformed
    }

    /// The stop times at the platforms of `stopIDs` (parent IDs, without the
    /// N / S suffix) in a FeedMessage. Stops the feed marks skipped or
    /// without data, and entities marked deleted, are left out.
    static func stopTimes(in data: Data, stopIDs: Set<String>) throws -> [StopTime] {
        let bytes = [UInt8](data)
        var message = ProtobufReader(bytes)
        var result: [StopTime] = []
        while let field = try message.nextField() {
            if field.number == 2, field.wireType == .lengthDelimited {
                var entity = try message.message()
                result += try entityStopTimes(&entity, stopIDs: stopIDs)
            } else {
                try message.skip(field.wireType)
            }
        }
        return result
    }

    // FeedEntity: id = 1, is_deleted = 2, trip_update = 3.
    private static func entityStopTimes(_ entity: inout ProtobufReader, stopIDs: Set<String>) throws -> [StopTime] {
        var isDeleted = false
        var stopTimes: [StopTime] = []
        while let field = try entity.nextField() {
            switch (field.number, field.wireType) {
            case (2, .varint):
                isDeleted = try entity.varint() != 0
            case (3, .lengthDelimited):
                var tripUpdate = try entity.message()
                stopTimes = try tripUpdateStopTimes(&tripUpdate, stopIDs: stopIDs)
            default:
                try entity.skip(field.wireType)
            }
        }
        return isDeleted ? [] : stopTimes
    }

    // TripUpdate: trip = 1, stop_time_update = 2.
    private static func tripUpdateStopTimes(_ update: inout ProtobufReader, stopIDs: Set<String>) throws -> [StopTime] {
        var route: String?
        var stops: [(stopID: String, direction: TransitDirection, time: Int64)] = []
        while let field = try update.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                var trip = try update.message()
                route = try routeID(&trip)
            case (2, .lengthDelimited):
                var stopTime = try update.message()
                if let stop = try platformStop(&stopTime, stopIDs: stopIDs) { stops.append(stop) }
            default:
                try update.skip(field.wireType)
            }
        }
        guard let route, !route.isEmpty else { return [] }
        return stops.map {
            StopTime(route: route, direction: $0.direction, time: Date(timeIntervalSince1970: TimeInterval($0.time)))
        }
    }

    // TripDescriptor: route_id = 5.
    private static func routeID(_ trip: inout ProtobufReader) throws -> String? {
        var route: String?
        while let field = try trip.nextField() {
            if field.number == 5, field.wireType == .lengthDelimited {
                route = try trip.string()
            } else {
                try trip.skip(field.wireType)
            }
        }
        return route
    }

    // StopTimeUpdate: arrival = 2, departure = 3, stop_id = 4,
    // schedule_relationship = 5 (0 scheduled, 1 skipped, 2 no data).
    private static func platformStop(
        _ update: inout ProtobufReader, stopIDs: Set<String>
    ) throws -> (stopID: String, direction: TransitDirection, time: Int64)? {
        var stopID: String?
        var arrival: Int64?
        var departure: Int64?
        var relationship: UInt64 = 0
        while let field = try update.nextField() {
            switch (field.number, field.wireType) {
            case (2, .lengthDelimited):
                var event = try update.message()
                arrival = try eventTime(&event)
            case (3, .lengthDelimited):
                var event = try update.message()
                departure = try eventTime(&event)
            case (4, .lengthDelimited):
                stopID = try update.string()
            case (5, .varint):
                relationship = try update.varint()
            default:
                try update.skip(field.wireType)
            }
        }
        guard relationship == 0, let stopID, let time = departure ?? arrival, time > 0,
              let direction = direction(of: stopID, stopIDs: stopIDs)
        else { return nil }
        return (stopID, direction, time)
    }

    // StopTimeEvent: time = 2 (POSIX seconds).
    private static func eventTime(_ event: inout ProtobufReader) throws -> Int64? {
        var time: Int64?
        while let field = try event.nextField() {
            if field.number == 2, field.wireType == .varint {
                let value = try event.varint()
                time = Int64(bitPattern: value)
            } else {
                try event.skip(field.wireType)
            }
        }
        return time
    }

    /// "A32N" → .north when "A32" is one of `stopIDs`.
    static func direction(of platformID: String, stopIDs: Set<String>) -> TransitDirection? {
        guard let last = platformID.last, stopIDs.contains(String(platformID.dropLast())) else { return nil }
        switch last {
        case "N": return .north
        case "S": return .south
        default: return nil
        }
    }
}

/// The protobuf wire format, read forward over a byte array. Each
/// length-delimited field read as a message gets its own reader over that
/// range, which must be used up before the parent goes on.
struct ProtobufReader {
    enum WireType: Equatable {
        case varint, fixed64, lengthDelimited, fixed32
    }

    private let bytes: [UInt8]
    private var index: Int
    private let end: Int

    init(_ bytes: [UInt8]) {
        self.init(bytes, range: 0..<bytes.count)
    }

    private init(_ bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        self.index = range.lowerBound
        self.end = range.upperBound
    }

    /// The next field's number and wire type, nil at the end. Groups
    /// (wire types 3 and 4, deprecated and absent from GTFS-Realtime) are
    /// refused as malformed.
    mutating func nextField() throws -> (number: Int, wireType: WireType)? {
        guard index < end else { return nil }
        let key = try varint()
        let number = Int(key >> 3)
        guard number > 0 else { throw GTFSRealtime.DecodeError.malformed }
        switch key & 7 {
        case 0: return (number, .varint)
        case 1: return (number, .fixed64)
        case 2: return (number, .lengthDelimited)
        case 5: return (number, .fixed32)
        default: throw GTFSRealtime.DecodeError.malformed
        }
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < end else { throw GTFSRealtime.DecodeError.truncated }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            // A varint is at most 10 bytes.
            guard shift < 70 else { throw GTFSRealtime.DecodeError.malformed }
        }
    }

    /// The range of a length-delimited field's bytes, moving past them.
    private mutating func lengthDelimited() throws -> Range<Int> {
        let length = try varint()
        guard length <= UInt64(end - index) else { throw GTFSRealtime.DecodeError.truncated }
        let range = index..<(index + Int(length))
        index = range.upperBound
        return range
    }

    /// A reader over the length-delimited field that comes next.
    mutating func message() throws -> ProtobufReader {
        let range = try lengthDelimited()
        return ProtobufReader(bytes, range: range)
    }

    mutating func string() throws -> String {
        let range = try lengthDelimited()
        return String(decoding: bytes[range], as: UTF8.self)
    }

    mutating func skip(_ wireType: WireType) throws {
        switch wireType {
        case .varint: _ = try varint()
        case .lengthDelimited: _ = try lengthDelimited()
        case .fixed64: try advance(8)
        case .fixed32: try advance(4)
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard end - index >= count else { throw GTFSRealtime.DecodeError.truncated }
        index += count
    }
}
