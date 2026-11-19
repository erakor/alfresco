// TransitAlerts.swift
//
// The MTA's service alerts at Config.transitStation, from the transit
// service's /subway/alerts?stop=: the alerts naming one of the station's
// stops, or a whole route that stops there, already sorted by the service
// (incidents first, then planned work; the most serious first). Off the main
// actor; TransitProvider keeps the last answer.

import Foundation

/// A route an alert is about, in the service's colors.
struct TransitRoute: Sendable, Equatable {
    let name: String
    /// sRGB, 0xRRGGBB.
    let color: UInt32
    let textColor: UInt32
}

/// One alert in effect now.
struct TransitAlert: Sendable, Equatable {
    let id: String
    /// Scheduled work (weekend reroutes, skipped stops at night) rather
    /// than an incident.
    let planned: Bool
    /// The MTA's status ("Delays", "Part Suspended"), nil when it has none.
    let category: String?
    /// Plain text; the MTA writes routes in brackets ("[A][C] trains…").
    let header: String
    let routes: [TransitRoute]

    /// What its first line in the menu says: the MTA's status, else what
    /// kind of alert it is.
    var categoryText: String {
        if let category, !category.isEmpty { return category }
        return planned ? "Planned work" : "Service alert"
    }
}

/// The alerts at the station, as fetched.
struct TransitAlerts: Sendable, Equatable {
    let alerts: [TransitAlert]
    /// When the answer arrived: how long it is reused.
    let fetchedAt: Date

    /// Incidents (delays, suspensions), the ones the menu bar icon marks.
    /// Planned work is listed in the menu but doesn't mark the icon: there
    /// is some most nights and weekends.
    var incidents: [TransitAlert] { alerts.filter { !$0.planned } }

    /// What the icon's tool tip and the menu say about them.
    var summary: String {
        let incidentCount = incidents.count
        let plannedCount = alerts.count - incidentCount
        var parts: [String] = []
        if incidentCount > 0 {
            parts.append(incidentCount == 1 ? "1 service alert" : "\(incidentCount) service alerts")
        }
        if plannedCount > 0 { parts.append(plannedCount == 1 ? "1 planned change" : "\(plannedCount) planned changes") }
        return parts.isEmpty ? "No service alerts" : parts.joined(separator: ", ")
    }
}

enum TransitAlertsLoader {
    /// The /subway/alerts answer, only the fields the menu uses.
    private struct Response: Decodable {
        struct Alert: Decodable {
            struct Route: Decodable {
                let name: String
                let color: String
                let textColor: String
            }

            let id: String
            let planned: Bool
            let category: String?
            let header: String
            let routes: [Route]
        }

        let alerts: [Alert]
    }

    /// The URL of `station`'s alerts.
    static func url(for station: String, service: TransitService) -> URL? {
        TransitLoader.url(path: "subway/alerts", station: station, service: service)
    }

    /// Decodes an answer of the service. nil when it isn't one.
    static func alerts(from data: Data, fetchedAt: Date) -> TransitAlerts? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let alerts = response.alerts.map { alert in
            TransitAlert(
                id: alert.id,
                planned: alert.planned,
                category: alert.category,
                header: alert.header.trimmingCharacters(in: .whitespacesAndNewlines),
                routes: alert.routes.map {
                    TransitRoute(
                        name: $0.name,
                        color: TransitLoader.routeColor($0.color),
                        textColor: TransitLoader.routeTextColor($0.textColor)
                    )
                }
            )
        }
        return TransitAlerts(alerts: alerts, fetchedAt: fetchedAt)
    }

    /// The alerts at `station` now. Throws TransitError, or
    /// CancellationError.
    static func load(_ station: String, service: TransitService) async throws -> TransitAlerts {
        guard let url = url(for: station, service: service) else { throw TransitError.badResponse }
        return try await TransitLoader.get(url, service: service, signpost: "transit.alerts") {
            alerts(from: $0, fetchedAt: Date())
        }
    }
}
