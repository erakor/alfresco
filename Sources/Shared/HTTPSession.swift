import Foundation

/// The URL session for the launcher's own requests (weather, previews).
/// Ephemeral, so nothing reaches the disk: no URL cache (the WeatherAPI key
/// is part of its request URLs) and no cookies.
enum HTTPSession {
    static let shared = URLSession(configuration: .ephemeral)
}
