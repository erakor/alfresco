import Foundation

/// The URL session for the launcher's own requests (weather, previews).
/// Nothing is cached and no cookies are kept or sent, even in memory: the
/// WeatherAPI key is part of its request URLs, and a preview host has no
/// business tracking the launcher. Redirects are only followed to https, so
/// neither the key nor what was typed for a preview is ever sent in clear text,
/// and a request carrying a service token (`credentialHeaders`) only to the
/// host it was sent to, so the token never reaches anyone else.
enum HTTPSession {
    /// Headers that hold a secret for one host. A request carrying one is
    /// never redirected to another origin (URLSession copies headers across
    /// redirects).
    static let credentialHeaders = [TransitService.tokenHeader]

    /// Same scheme, host (case-insensitive) and port, the default port
    /// counting as written: where a token may go.
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let scheme = a.scheme?.lowercased(), scheme == b.scheme?.lowercased(),
              let host = a.host?.lowercased(), !host.isEmpty, host == b.host?.lowercased()
        else { return false }
        return port(of: a) == port(of: b)
    }

    private static func port(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// Whether a redirect from `original` to `redirect` is followed: only to
    /// https, and only to the same origin when it carries a credential header.
    static func allowsRedirect(from original: URLRequest?, to redirect: URLRequest) -> Bool {
        guard let target = redirect.url, target.scheme?.lowercased() == "https" else { return false }
        let carriesCredential = credentialHeaders.contains { redirect.value(forHTTPHeaderField: $0) != nil }
            || credentialHeaders.contains { original?.value(forHTTPHeaderField: $0) != nil }
        guard carriesCredential else { return true }
        guard let source = original?.url else { return false }
        return sameOrigin(source, target)
    }

    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: HTTPSRedirectsOnly(), delegateQueue: nil)
    }()

    /// Builds before this one used URLSession.shared, whose disk cache can
    /// still hold weather responses with the key in their URL. Nothing uses
    /// that cache any more, so emptying it at each launch costs nothing.
    static func removeLegacyCache() {
        URLCache.shared.removeAllCachedResponses()
    }
}

/// Refuses a redirect to anything but https (an https server answering with
/// a redirect to http, say), and a token-carrying request's redirect to
/// another origin (HTTPSession.allowsRedirect). The request then ends with
/// the redirect response itself, which callers treat as a failure.
private final class HTTPSRedirectsOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        HTTPSession.allowsRedirect(from: task.originalRequest, to: request) ? request : nil
    }
}
