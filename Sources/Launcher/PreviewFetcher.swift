// PreviewFetcher.swift
//
// Fetches a workflow's `preview` URL while the launcher is open and keeps the
// short plain-text answers for as long as the server says (at most a few
// minutes), so the hint can show e.g. the weather before Enter is pressed.
// A preview on the transit service's host carries its token.

import Foundation

@MainActor
final class PreviewFetcher {
    /// Waits this long after the input settles before sending anything, so
    /// "weather p", "weather pa", ... are not each sent while typing.
    private static let debounceNanoseconds: UInt64 = 400_000_000
    private static let maxEntries = 50

    /// Called on the main actor when a new answer is in the cache.
    var onUpdate: (@MainActor () -> Void)?

    /// Keyed by Command.preview, before a `{service}` address is filled in.
    private var cache: [URL: (text: String, expiresAt: Date)] = [:]
    private var task: Task<Void, Never>?
    /// The URL being waited on or fetched, if any.
    private var pendingURL: URL?

    /// The answer for `url` if one was fetched recently.
    func cachedText(for url: URL) -> String? {
        guard let entry = cache[url] else { return nil }
        guard Date() < entry.expiresAt else {
            cache[url] = nil
            return nil
        }
        return entry.text
    }

    /// Fetches `url` after the debounce delay, replacing any fetch for a
    /// different URL that has not finished. Calls `onUpdate` once the answer
    /// is cached. Failures (offline, timeout, error status, HTML instead of
    /// text, a `{service}` preview with no service set up) are silent: the
    /// hint simply keeps showing the plain label.
    func fetch(_ url: URL) {
        guard url != pendingURL else { return }
        cancel()
        pendingURL = url
        // Read now, like the transit board: the files can change while the
        // app runs. Kept as pending when nil, so it isn't read per keystroke.
        guard let request = PreviewRequest.make(url, service: Config.transitService()) else { return }
        task = Task { [weak self] in
            let answer: (text: String, lifetime: TimeInterval)
            do {
                try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                answer = try await PreviewLoader.load(request)
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
            self.cache[url] = (answer.text, Date().addingTimeInterval(answer.lifetime))
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

/// What is sent for a preview: its `{service}` address filled in, and the
/// service's token when the URL is on the service's own origin. Pure, so the
/// self-test checks where the token goes.
enum PreviewRequest {
    static let timeout: TimeInterval = 5
    /// How long an answer is kept without `max-age`, and at most with one.
    static let maxLifetime: TimeInterval = 10 * 60
    /// At least this long, even for `max-age=0` or `no-store`, so the line
    /// is shown at all.
    static let minLifetime: TimeInterval = 5

    /// The request for Command.preview `url`, nil for a `{service}` preview
    /// with no service set up, or anything that isn't https.
    static func make(_ url: URL, service: TransitService?) -> URLRequest? {
        guard let target = resolve(url, service: service), target.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let service, HTTPSession.sameOrigin(target, service.baseURL) {
            request.setValue(service.token, forHTTPHeaderField: TransitService.tokenHeader)
        }
        return request
    }

    /// `alfresco-service:/p?q=x` as `<service address>/p?q=x`; other URLs
    /// as they are.
    static func resolve(_ url: URL, service: TransitService?) -> URL? {
        guard url.scheme == Workflow.serviceScheme else { return url }
        guard let service else { return nil }
        let rest = url.absoluteString.dropFirst(Workflow.serviceScheme.count + 1)
        guard rest.hasPrefix("/") else { return nil }
        var base = service.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + String(rest))
    }

    /// How long to keep an answer: the response's `max-age` between
    /// minLifetime and maxLifetime (not `s-maxage`, which is the CDN's),
    /// minLifetime for `no-store` / `no-cache`, else maxLifetime.
    static func lifetime(cacheControl: String?) -> TimeInterval {
        guard let cacheControl else { return maxLifetime }
        for directive in cacheControl.lowercased().split(separator: ",") {
            let parts = directive.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts[0] == "no-store" || parts[0] == "no-cache" { return minLifetime }
            if parts.count == 2, parts[0] == "max-age",
               let seconds = Double(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))),
               seconds.isFinite {
                return min(max(seconds, minLifetime), maxLifetime)
            }
        }
        return maxLifetime
    }
}

/// The network part, off the main actor.
private enum PreviewLoader {
    /// More than enough for one line; the rest of a longer answer is ignored.
    static let maxBytes = 1024

    /// The first non-empty line of the response, if the server answered 2xx
    /// with something that is not HTML, and how long to keep it. Only the
    /// first `maxBytes` are read: the download stops there, however long the
    /// answer is.
    static func load(_ request: URLRequest) async throws -> (text: String, lifetime: TimeInterval) {
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval("preview.load", id: signposter.makeSignpostID())
        var outcome = Signposts.Kind.failed
        var bytes = 0
        defer { Signposts.end("preview.load", signpost, outcome, bytes: bytes) }
        var data = Data()
        var lifetime = PreviewRequest.maxLifetime
        do {
            let (stream, response) = try await HTTPSession.shared.bytes(for: request)
            defer { stream.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            lifetime = PreviewRequest.lifetime(cacheControl: http.value(forHTTPHeaderField: "Cache-Control"))
            for try await byte in stream {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { outcome = .cancelled }
            throw error
        }
        bytes = data.count
        let text = String(decoding: data, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !line.isEmpty, !line.hasPrefix("<") else { throw URLError(.cannotParseResponse) }
        outcome = .ok
        return (line, lifetime)
    }
}
