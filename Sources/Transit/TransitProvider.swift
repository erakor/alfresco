// TransitProvider.swift
//
// Main-actor side of the departure board: keeps the last snapshot of
// Config.transitStation's trains, fetches a new one through TransitLoader
// once it is older than Config.transitCacheLifetime (one request at a
// time), and calls onUpdate when it arrives.

import Foundation

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

    /// Called on the main actor when a fetch ends.
    var onUpdate: (@MainActor () -> Void)?

    /// nil turns the feature off.
    let station: TransitStation? = Config.transitStation

    private var snapshot: TransitSnapshot?
    private var failure: (message: String, at: Date)?
    private var task: Task<Void, Never>?

    /// What to show at `now`: the last snapshot while it is recent enough
    /// (a newer one may be on its way), else the last failure, else loading.
    func state(now: Date = Date()) -> TransitState {
        if let snapshot, now.timeIntervalSince(snapshot.fetchedAt) < Self.snapshotLifetime {
            return .loaded(snapshot)
        }
        if let failure { return .failed(failure.message) }
        return .loading
    }

    /// Fetches a new snapshot unless the last one is fresh, a failure is
    /// recent, or a fetch is already running. The self-test build never
    /// fetches: its launcher would reach the MTA on every run.
    func refreshIfStale(now: Date = Date()) {
        guard task == nil, let station else { return }
        if let snapshot, now.timeIntervalSince(snapshot.fetchedAt) < Config.transitCacheLifetime { return }
        if let failure, now.timeIntervalSince(failure.at) < Self.failureLifetime { return }
        #if SELFTEST
        _ = station
        #else
        load(station)
        #endif
    }

    /// Stops a fetch in progress (the launcher closed).
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func load(_ station: TransitStation) {
        task = Task { [weak self] in
            let result: Result<TransitSnapshot, TransitError>
            do {
                let snapshot = try await TransitLoader.load(station)
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
            self.onUpdate?()
        }
    }

    #if SELFTEST
    /// Stands in for a fetch.
    func setSnapshotForSelfTest(_ snapshot: TransitSnapshot?) {
        self.snapshot = snapshot
        failure = nil
    }
    #endif
}
