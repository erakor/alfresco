import Foundation

/// The URL session for the launcher's own requests (weather, previews).
/// Nothing is cached and no cookies are kept or sent, even in memory: the
/// WeatherAPI key is part of its request URLs, and a preview host has no
/// business tracking the launcher.
enum HTTPSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// Builds before this one used URLSession.shared, whose disk cache can
    /// still hold weather responses with the key in their URL. Nothing uses
    /// that cache any more, so emptying it at each launch costs nothing.
    static func removeLegacyCache() {
        URLCache.shared.removeAllCachedResponses()
    }
}
