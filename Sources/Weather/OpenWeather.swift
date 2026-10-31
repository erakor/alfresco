// OpenWeather.swift
//
// The network side of the weather panel, off the main actor: finds the
// place (OpenWeather geocoding, or ipinfo.io for "where I am"), fetches the
// current weather and the 5-day / 3-hour forecast from OpenWeather's free
// plan, and turns them into a Forecast with one entry per day.

import Foundation

/// What the launcher input asks for: `weather` alone or `weather <place>`.
enum WeatherQuery: Hashable, Sendable {
    case here
    /// Lowercased, so "Paris" and "paris" share a cache entry.
    case place(String)
}

struct Forecast: Sendable {
    struct Day: Sendable {
        /// Short weekday name, or "Auj." for today.
        let name: String
        let low: Double
        let high: Double
        /// OpenWeather icon code, e.g. "10d".
        let icon: String
        /// Highest chance of precipitation that day, 0...1.
        let rainChance: Double
    }

    /// e.g. "Paris, FR".
    let place: String
    /// The place came from the IP address, so it may be off by a city.
    let isApproximate: Bool
    let temperature: Double
    let feelsLike: Double
    let humidity: Double
    let windKmh: Double
    /// Where the wind comes from, in degrees (0 = north).
    let windDegrees: Double?
    let description: String
    let icon: String
    /// Chance of precipitation in the next 3 hours, 0...1.
    let rainChance: Double?
    let days: [Day]
}

enum WeatherError: Error, Sendable {
    case badKey
    case rateLimited
    case unknownPlace(String)
    case noLocation
    case offline
    case server(Int)
    case badResponse

    var message: String {
        switch self {
        case .badKey:
            return "OpenWeather a refusé la clé. Une nouvelle clé peut mettre quelques heures à s'activer."
        case .rateLimited:
            return "Trop de requêtes OpenWeather, réessayez dans une minute."
        case .unknownPlace(let place):
            return "Lieu introuvable : \(place)"
        case .noLocation:
            return "Position introuvable. Tapez un lieu, ou réglez Config.weatherHomePlace."
        case .offline:
            return "Pas de connexion à OpenWeather."
        case .server(let status):
            return "OpenWeather : erreur \(status)."
        case .badResponse:
            return "Réponse OpenWeather illisible."
        }
    }
}

enum WeatherLoader {
    private static let timeout: TimeInterval = 8

    private struct Location: Sendable {
        let latitude: Double
        let longitude: Double
        let name: String?
        let isApproximate: Bool
    }

    /// Three requests for a place (geocoding, current, forecast), or one to
    /// ipinfo.io and two to OpenWeather for `.here`. Throws WeatherError or
    /// CancellationError.
    static func load(_ query: WeatherQuery, key: String) async throws -> Forecast {
        let language = Config.weatherLanguage
        let location: Location
        switch query {
        case .here: location = try await ipLocation()
        case .place(let name): location = try await geocode(name, key: key, language: language)
        }

        let items = [
            URLQueryItem(name: "lat", value: String(location.latitude)),
            URLQueryItem(name: "lon", value: String(location.longitude)),
            URLQueryItem(name: "units", value: "metric"),
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "appid", value: key),
        ]
        let currentURL = try url("data/2.5/weather", items)
        let forecastURL = try url("data/2.5/forecast", items)
        async let currentResponse: CurrentResponse = get(currentURL)
        async let forecastResponse: ForecastResponse = get(forecastURL)
        let (current, forecast) = try await (currentResponse, forecastResponse)
        return try makeForecast(location: location, current: current, forecast: forecast, language: language)
    }

    // MARK: Finding the place

    private static func geocode(_ name: String, key: String, language: String) async throws -> Location {
        let results: [GeocodeResult] = try await get(try url("geo/1.0/direct", [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "appid", value: key),
        ]))
        guard let place = results.first else { throw WeatherError.unknownPlace(name) }
        let localName = place.localNames?[language] ?? place.name
        let label = [localName, place.country].compactMap { $0 }.joined(separator: ", ")
        return Location(latitude: place.lat, longitude: place.lon, name: label, isApproximate: false)
    }

    /// ipinfo.io's free, keyless lookup of the public IP address.
    private static func ipLocation() async throws -> Location {
        guard let url = URL(string: "https://ipinfo.io/json") else { throw WeatherError.noLocation }
        let info: IPInfo
        do {
            info = try await get(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WeatherError.noLocation
        }
        let parts = (info.loc ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { throw WeatherError.noLocation }
        let label = [info.city, info.country].compactMap { $0 }.joined(separator: ", ")
        return Location(latitude: parts[0], longitude: parts[1], name: label.isEmpty ? nil : label, isApproximate: true)
    }

    // MARK: Building the forecast

    private static func makeForecast(
        location: Location, current: CurrentResponse, forecast: ForecastResponse, language: String
    ) throws -> Forecast {
        guard let condition = current.weather.first else { throw WeatherError.badResponse }

        // The 3-hour slots, grouped by day in the place's own time zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: forecast.city.timezone) ?? TimeZone(identifier: "UTC") ?? .current
        var dayStarts: [Date] = []
        var slotsByDay: [Date: [ForecastResponse.Slot]] = [:]
        for slot in forecast.list {
            let start = calendar.startOfDay(for: Date(timeIntervalSince1970: slot.dt))
            if slotsByDay[start] == nil { dayStarts.append(start) }
            slotsByDay[start, default: []].append(slot)
        }

        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: language)
        weekday.timeZone = calendar.timeZone
        weekday.dateFormat = "EEE"
        let today = calendar.startOfDay(for: Date())

        let days: [Forecast.Day] = dayStarts.prefix(5).compactMap { start in
            guard let slots = slotsByDay[start], !slots.isEmpty else { return nil }
            var low = slots.map(\.main.tempMin).min() ?? 0
            var high = slots.map(\.main.tempMax).max() ?? 0
            let isToday = start == today
            if isToday {
                // Today only has the hours still to come; count the current
                // temperature too.
                low = min(low, current.main.temp)
                high = max(high, current.main.temp)
            }
            // The icon of the slot nearest 13:00, shown as its day version.
            let midday = slots.min { a, b in
                abs(WeatherLoader.hour(of: a, in: calendar) - 13) < abs(WeatherLoader.hour(of: b, in: calendar) - 13)
            }
            var icon = midday?.weather.first?.icon ?? condition.icon
            if icon.hasSuffix("n") { icon = String(icon.dropLast()) + "d" }
            let name = isToday ? "Auj." : weekday.string(from: start).capitalized(with: weekday.locale)
            return Forecast.Day(
                name: name, low: low, high: high, icon: icon,
                rainChance: slots.compactMap(\.pop).max() ?? 0
            )
        }

        return Forecast(
            place: location.name ?? [current.name, current.sys?.country].compactMap { $0 }.joined(separator: ", "),
            isApproximate: location.isApproximate,
            temperature: current.main.temp,
            feelsLike: current.main.feelsLike,
            humidity: current.main.humidity,
            windKmh: (current.wind?.speed ?? 0) * 3.6,
            windDegrees: current.wind?.deg,
            description: condition.description,
            icon: condition.icon,
            rainChance: forecast.list.first?.pop,
            days: days
        )
    }

    private static func hour(of slot: ForecastResponse.Slot, in calendar: Calendar) -> Int {
        calendar.component(.hour, from: Date(timeIntervalSince1970: slot.dt))
    }

    // MARK: HTTP

    private static func url(_ path: String, _ items: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: "https://api.openweathermap.org/" + path) else {
            throw WeatherError.badResponse
        }
        components.queryItems = items
        guard let url = components.url else { throw WeatherError.badResponse }
        return url
    }

    private static func get<T: Decodable & Sendable>(_ url: URL) async throws -> T {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WeatherError.offline
        }
        guard let http = result.1 as? HTTPURLResponse else { throw WeatherError.badResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw WeatherError.badKey
        case 429: throw WeatherError.rateLimited
        default: throw WeatherError.server(http.statusCode)
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: result.0)
        } catch {
            throw WeatherError.badResponse
        }
    }
}

// MARK: - Response models (only the fields used)

private struct Condition: Decodable, Sendable {
    let description: String
    let icon: String
}

private struct GeocodeResult: Decodable, Sendable {
    let name: String
    let localNames: [String: String]?
    let lat: Double
    let lon: Double
    let country: String?
}

private struct IPInfo: Decodable, Sendable {
    let city: String?
    let country: String?
    /// "48.8534,2.3488"
    let loc: String?
}

private struct CurrentResponse: Decodable, Sendable {
    struct Main: Decodable, Sendable {
        let temp: Double
        let feelsLike: Double
        let humidity: Double
    }
    struct Wind: Decodable, Sendable {
        /// Meters per second with units=metric.
        let speed: Double
        let deg: Double?
    }
    struct Sys: Decodable, Sendable {
        let country: String?
    }
    let weather: [Condition]
    let main: Main
    let wind: Wind?
    let name: String?
    let sys: Sys?
}

private struct ForecastResponse: Decodable, Sendable {
    struct Slot: Decodable, Sendable {
        struct Main: Decodable, Sendable {
            let tempMin: Double
            let tempMax: Double
        }
        let dt: TimeInterval
        let main: Main
        let weather: [Condition]
        /// Probability of precipitation, 0...1.
        let pop: Double?
    }
    struct City: Decodable, Sendable {
        /// Offset from UTC in seconds.
        let timezone: Int
    }
    let list: [Slot]
    let city: City
}
