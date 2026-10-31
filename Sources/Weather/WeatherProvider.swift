// WeatherProvider.swift
//
// Main-actor side of the weather panel: reads the WeatherAPI key, turns
// launcher input into a WeatherQuery, and runs WeatherLoader with a debounce,
// one request at a time, caching results for Config.weatherCacheLifetime.

import Foundation

enum WeatherState: Sendable {
    case loading
    case loaded(Forecast)
    case failed(String)
}

@MainActor
final class WeatherProvider {
    /// Waits this long after the input settles before looking up a typed
    /// place, so "weather p", "weather pa", ... are not each sent.
    private static let debounceNanoseconds: UInt64 = 400_000_000
    /// A failure is shown for this long before the same query is retried.
    private static let failureLifetime: TimeInterval = 30
    private static let maxEntries = 50

    /// Called on the main actor when a result for any query arrives.
    var onUpdate: (@MainActor () -> Void)?

    private var apiKey: String?
    private var results: [WeatherQuery: (state: WeatherState, at: Date)] = [:]
    private var task: Task<Void, Never>?
    /// The query being waited on or fetched, if any.
    private var pending: WeatherQuery?

    init() {
        reloadKey()
    }

    /// Re-reads the key, so adding or changing it needs no restart. Cheap;
    /// called each time the launcher opens.
    func reloadKey() {
        let key = Config.weatherAPIKey()
        if key != apiKey {
            apiKey = key
            results.removeAll()
        }
    }

    /// `weather` → `.here` (or the home place), `weather <place>` → `.place`.
    /// nil for anything else, and always nil without an API key, so the
    /// launcher then behaves as if this feature did not exist.
    func query(for input: String) -> WeatherQuery? {
        guard apiKey != nil else { return nil }
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let keyword = parts.first, keyword.lowercased() == Config.weatherKeyword else { return nil }
        if parts.count == 2 {
            let place = parts[1].trimmingCharacters(in: .whitespaces)
            if !place.isEmpty { return .place(place.lowercased()) }
        }
        return homeQuery()
    }

    /// Where the bare keyword (and the idle launcher) looks: the home place,
    /// or the IP address. nil without an API key.
    func homeQuery() -> WeatherQuery? {
        guard apiKey != nil else { return nil }
        if let home = Config.weatherHomePlace { return .place(home.lowercased()) }
        return .here
    }

    /// What to show for `query` right now.
    func state(for query: WeatherQuery) -> WeatherState {
        guard let entry = results[query], isFresh(entry) else { return .loading }
        return entry.state
    }

    /// Fetches `query` unless a fresh result is cached or it is already on its
    /// way. Replaces a fetch for a different query. Calls `onUpdate` when done.
    func request(_ query: WeatherQuery) {
        if let entry = results[query], isFresh(entry) {
            cancel()
            return
        }
        guard query != pending, let key = apiKey else { return }
        cancel()
        pending = query

        task = Task { [weak self] in
            if case .place = query {
                do {
                    try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                } catch {
                    return
                }
            }
            let state: WeatherState
            do {
                let forecast = try await WeatherLoader.load(query, key: key)
                state = .loaded(forecast)
            } catch is CancellationError {
                return
            } catch let error as WeatherError {
                state = .failed(error.message)
            } catch {
                state = .failed(WeatherError.badResponse.message)
            }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            if self.results.count >= Self.maxEntries { self.results.removeAll() }
            self.results[query] = (state, Date())
            self.onUpdate?()
        }
    }

    /// Stops a fetch in progress or waiting on the debounce delay.
    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }

    private func isFresh(_ entry: (state: WeatherState, at: Date)) -> Bool {
        let age = Date().timeIntervalSince(entry.at)
        switch entry.state {
        case .loading: return false
        case .loaded: return age < Config.weatherCacheLifetime
        case .failed: return age < Self.failureLifetime
        }
    }
}
