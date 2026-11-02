// PreviewFetcher.swift
//
// Fetches a workflow's `preview` URL while the launcher is open and keeps the
// short plain-text answers for a few minutes, so the hint can show e.g. the
// weather before Enter is pressed.

import Foundation

@MainActor
final class PreviewFetcher {
    /// Waits this long after the input settles before sending anything, so
    /// "weather p", "weather pa", ... are not each sent while typing.
    private static let debounceNanoseconds: UInt64 = 400_000_000
    /// How long an answer is reused before it is fetched again.
    private static let lifetime: TimeInterval = 10 * 60
    private static let maxEntries = 50

    /// Called on the main actor when a new answer is in the cache.
    var onUpdate: (@MainActor () -> Void)?

    private var cache: [URL: (text: String, fetchedAt: Date)] = [:]
    private var task: Task<Void, Never>?
    /// The URL being waited on or fetched, if any.
    private var pendingURL: URL?

    /// The answer for `url` if one was fetched recently.
    func cachedText(for url: URL) -> String? {
        guard let entry = cache[url] else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < Self.lifetime else {
            cache[url] = nil
            return nil
        }
        return entry.text
    }

    /// Fetches `url` after the debounce delay, replacing any fetch for a
    /// different URL that has not finished. Calls `onUpdate` once the answer
    /// is cached. Failures (offline, timeout, error status, HTML instead of
    /// text) are silent: the hint simply keeps showing the plain label.
    func fetch(_ url: URL) {
        guard url != pendingURL else { return }
        cancel()
        pendingURL = url
        task = Task { [weak self] in
            let text: String
            do {
                try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                text = try await PreviewLoader.load(url)
            } catch {
                if let self, self.pendingURL == url { self.pendingURL = nil }
                // Cancelled means replaced or closed, not failed.
                if !Task.isCancelled { UsageStats.shared.record(.previewFailed) }
                return
            }
            guard let self, !Task.isCancelled else { return }
            UsageStats.shared.record(.previewLoaded)
            self.pendingURL = nil
            if self.cache.count >= Self.maxEntries { self.cache.removeAll() }
            self.cache[url] = (text, Date())
            self.onUpdate?()
        }
    }

    /// Stops a fetch in progress or waiting on the debounce delay.
    func cancel() {
        task?.cancel()
        task = nil
        pendingURL = nil
    }
}

/// The network part, off the main actor.
private enum PreviewLoader {
    static let timeout: TimeInterval = 5
    /// More than enough for one line; the rest of a longer answer is ignored.
    static let maxBytes = 1024

    /// The first non-empty line of the response, if the server answered 2xx
    /// with something that is not HTML.
    static func load(_ url: URL) async throws -> String {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (data, response) = try await HTTPSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let text = String(decoding: data.prefix(maxBytes), as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !line.isEmpty, !line.hasPrefix("<") else { throw URLError(.cannotParseResponse) }
        return line
    }
}
