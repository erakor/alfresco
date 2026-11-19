// TransitProvider.swift
//
// Main-actor side of the departure board: keeps the last snapshot of
// Config.transitStation's trains, fetches a new one through TransitLoader
// once it is older than Config.transitCacheLifetime (one request at a
// time), and tells its observers when it arrives. It also keeps the
// station's service alerts (TransitAlertsLoader), fetched on their own.
// One provider serves the launcher's board and the menu bar item
// (AppDelegate makes it). The service's address and token come from
// Config.transitService(), read before each fetch.

import Foundation

/// What a finished fetch changed.
enum TransitChange: Sendable {
    case trains, alerts
}

enum TransitState: Sendable {
    case loading
    case loaded(TransitSnapshot)
    case failed(String)
}

@MainActor
final class TransitProvider {
    /// A snapshot this old is no longer shown, even while a new one fails:
    /// its trains have left.
    static let snapshotLifetime: TimeInterval = 3 * 60
    /// A failure waits this long before the next try.
    private static let failureLifetime: TimeInterval = 15

    /// Alerts are reused this long when the menu opens (the service caches
    /// them for as long).
    static let alertsLifetime: TimeInterval = 60
    /// Alerts this old are no longer shown: they may have been lifted.
    static let alertsShownFor: TimeInterval = 30 * 60

    private var observers: [@MainActor (TransitChange) -> Void] = []

    /// nil turns the feature off.
    let station: String? = Config.transitStation
    /// Shown while no service is set up.
    static let setupMessage = "Set the transit service's address and token: see Sources/Transit/README.md."

    private var snapshot: TransitSnapshot?
    private var failure: (message: String, at: Date)?
    private var task: Task<Void, Never>?
    /// The last refreshIfStale found no service set up, so `state` can say
    /// so without reading the settings files again.
    private var serviceMissing = false
    private var alerts: TransitAlerts?
    private var alertsFailedAt: Date?
    private var alertsTask: Task<Void, Never>?

    /// Runs `observer` each time a fetch ends, with what it changed.
    func addObserver(_ observer: @escaping @MainActor (TransitChange) -> Void) {
        observers.append(observer)
    }

    private func notify(_ change: TransitChange) {
        for observer in observers { observer(change) }
    }

    /// What to show at `now`: the last snapshot while it is recent enough
    /// (a newer one may be on its way), else the last failure, else how to
    /// set up the service when it isn't, else loading.
    func state(now: Date = Date()) -> TransitState {
        if let snapshot, now.timeIntervalSince(snapshot.fetchedAt) < Self.snapshotLifetime {
            return .loaded(snapshot)
        }
        if let failure { return .failed(failure.message) }
        return serviceMissing ? .failed(Self.setupMessage) : .loading
    }

    /// Fetches a new snapshot unless the last one is fresh, a failure is
    /// recent, a fetch is already running, or no service is set up (always
    /// so in the self-test build, see Config.transitService). Callers run it
    /// before `state`, which reports what it found.
    func refreshIfStale(now: Date = Date()) {
        guard task == nil, let station else { return }
        if let snapshot, now.timeIntervalSince(snapshot.fetchedAt) < Config.transitCacheLifetime { return }
        if let failure, now.timeIntervalSince(failure.at) < Self.failureLifetime { return }
        // Read last: it reads the settings files.
        let service = Config.transitService()
        serviceMissing = service == nil
        guard let service else { return }
        load(station, service: service)
    }

    /// The station's alerts at `now`, nil before the first answer and once
    /// the last one is too old to trust.
    func currentAlerts(now: Date = Date()) -> TransitAlerts? {
        guard let alerts, now.timeIntervalSince(alerts.fetchedAt) < Self.alertsShownFor else { return nil }
        return alerts
    }

    /// Whether the menu bar icon shows its dot at `now`: background checks
    /// are on and an incident (not planned work) is in effect.
    func marksIcon(now: Date = Date()) -> Bool {
        Config.transitAlertCheckInterval != nil && !(currentAlerts(now: now)?.incidents.isEmpty ?? true)
    }

    /// Fetches the alerts unless the last answer is younger than
    /// `alertsLifetime`, a failure is recent, a fetch is already running, or
    /// no service is set up. Never cancelled: the menu bar icon waits
    /// on it.
    func refreshAlertsIfStale(now: Date = Date()) {
        guard alertsTask == nil, let station else { return }
        if let alerts, now.timeIntervalSince(alerts.fetchedAt) < Self.alertsLifetime { return }
        if let alertsFailedAt, now.timeIntervalSince(alertsFailedAt) < Self.failureLifetime { return }
        // Read last: it reads the settings files.
        guard let service = Config.transitService() else { return }
        alertsTask = Task { [weak self] in
            let result: TransitAlerts?
            do {
                result = try await TransitAlertsLoader.load(station, service: service)
            } catch is CancellationError {
                return
            } catch let error as TransitError {
                UsageStats.shared.recordTransitAlertsFailure(error)
                result = nil
            } catch {
                UsageStats.shared.recordTransitAlertsFailure(.badResponse)
                result = nil
            }
            guard let self else { return }
            self.alertsTask = nil
            if let result {
                UsageStats.shared.record(.transitAlertsLoaded)
                self.alerts = result
                self.alertsFailedAt = nil
            } else {
                self.alertsFailedAt = Date()
            }
            self.notify(.alerts)
        }
    }

    private func load(_ station: String, service: TransitService) {
        task = Task { [weak self] in
            let result: Result<TransitSnapshot, TransitError>
            do {
                let snapshot = try await TransitLoader.load(station, limit: Config.transitDepartures, service: service)
                result = .success(snapshot)
            } catch is CancellationError {
                return
            } catch let error as TransitError {
                result = .failure(error)
            } catch {
                result = .failure(.badResponse)
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            switch result {
            case .success(let snapshot):
                UsageStats.shared.record(.transitLoaded)
                self.snapshot = snapshot
                self.failure = nil
            case .failure(let error):
                UsageStats.shared.recordTransitFailure(error)
                self.failure = (error.message, Date())
            }
            self.notify(.trains)
        }
    }

    #if SELFTEST
        /// Stands in for a fetch.
        func setSnapshotForSelfTest(_ snapshot: TransitSnapshot?) {
            self.snapshot = snapshot
            failure = nil
        }

        /// Stands in for an alerts fetch.
        func setAlertsForSelfTest(_ alerts: TransitAlerts?) {
            self.alerts = alerts
            alertsFailedAt = nil
        }
    #endif
}
