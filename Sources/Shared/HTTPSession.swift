import Foundation

/// The URL session for the launcher's own requests (weather, previews).
/// Nothing is cached and no cookies are kept or sent, even in memory: the
/// WeatherAPI key is part of its request URLs, and a preview host has no
/// business tracking the launcher. Redirects are only followed to https, so
/// neither the key nor what was typed for a preview is ever sent in clear text.
enum HTTPSession {
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
/// a redirect to http, say). The request then ends with the redirect
/// response itself, which callers treat as a failure.
private final class HTTPSRedirectsOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}
