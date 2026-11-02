// WeatherAPI.swift
//
// The network side of the weather panel, off the main actor: one request to
// WeatherAPI.com's forecast endpoint (free plan) returns the place, the
// current weather and the hourly and daily forecasts, which become a Forecast.

import Foundation

/// What the launcher input asks for: `weather` alone or `weather <place>`.
enum WeatherQuery: Hashable, Sendable {
    /// Located from the public IP address (WeatherAPI's `auto:ip`).
    case here
    /// Lowercased, so "Paris" and "paris" share a cache entry.
    case place(String)
}

/// A WeatherAPI condition code (1000 = clear, 1183 = light rain, ...) and
/// whether it is daytime, which together pick the icon.
struct WeatherCondition: Sendable {
    let code: Int
    let isDay: Bool
}

struct Forecast: Sendable {
    struct Hour: Sendable {
        /// "Maint." for the current hour, else "15h", in the place's time zone.
        let name: String
        let temperature: Double
        let condition: WeatherCondition
        /// Chance of rain or snow during that hour, 0...1.
        let rainChance: Double
    }

    struct Day: Sendable {
        /// Short weekday name, or "Auj." for today.
        let name: String
        let low: Double
        let high: Double
        let condition: WeatherCondition
        /// Chance of rain or snow that day, 0...1.
        let rainChance: Double
    }

    /// e.g. "Paris, France".
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
    let condition: WeatherCondition
    /// Chance of rain or snow during the current hour, 0...1.
    let rainChance: Double?
    /// Config.weatherHours hours from the current one (fewer near the end
    /// of the forecast).
    let hours: [Hour]
    /// When the hour labeled "Maint." ends; after that the cached forecast
    /// is out of date. nil when the response had no current hour slot.
    let currentHourEnd: Date?
    let days: [Day]
}

enum WeatherError: Error, Sendable {
    case badKey
    case quotaExceeded
    case unknownPlace(String)
    case noLocation
    case offline
    case server(Int)
    case badResponse

    var message: String {
        switch self {
        case .badKey:
            return "WeatherAPI a refusé la clé. Vérifiez ~/.config/alfresco/weatherapi-key."
        case .quotaExceeded:
            return "Quota WeatherAPI du mois atteint."
        case .unknownPlace(let place):
            return "Lieu introuvable : \(place)"
        case .noLocation:
            return "Position introuvable. Tapez un lieu, ou réglez Config.weatherHomePlace."
        case .offline:
            return "Pas de connexion à WeatherAPI."
        case .server(let status):
            return "WeatherAPI : erreur \(status)."
        case .badResponse:
            return "Réponse WeatherAPI illisible."
        }
    }

    /// The case's name in usage.json ("weather.failed.<name>"), without the
    /// place or status code.
    var usageName: String {
        switch self {
        case .badKey: return "badKey"
        case .quotaExceeded: return "quotaExceeded"
        case .unknownPlace: return "unknownPlace"
        case .noLocation: return "noLocation"
        case .offline: return "offline"
        case .server: return "server"
        case .badResponse: return "badResponse"
        }
    }
}

enum WeatherLoader {
    private static let timeout: TimeInterval = 8

    /// One request. Throws WeatherError or CancellationError.
    static func load(_ query: WeatherQuery, key: String) async throws -> Forecast {
        let q: String
        switch query {
        case .here: q = "auto:ip"
        case .place(let name): q = name
        }
        guard var components = URLComponents(string: "https://api.weatherapi.com/v1/forecast.json") else {
            throw WeatherError.badResponse
        }
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "days", value: String(Config.weatherDays)),
            URLQueryItem(name: "lang", value: Config.weatherLanguage),
            URLQueryItem(name: "aqi", value: "no"),
            URLQueryItem(name: "alerts", value: "no"),
        ]
        guard let url = components.url else { throw WeatherError.badResponse }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let result: (Data, URLResponse)
        do {
            result = try await HTTPSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WeatherError.offline
        }
        guard let http = result.1 as? HTTPURLResponse else { throw WeatherError.badResponse }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (200..<300).contains(http.statusCode) else {
            // Errors come as {"error": {"code": 1006, "message": "..."}}.
            let code = (try? decoder.decode(ErrorResponse.self, from: result.0))?.error.code
            switch (http.statusCode, code) {
            case (_, 1006?): throw query == .here ? WeatherError.noLocation : WeatherError.unknownPlace(q)
            case (_, 2007?): throw WeatherError.quotaExceeded
            case (_, 1002?), (_, 2006?), (_, 2008?), (401, _): throw WeatherError.badKey
            default: throw WeatherError.server(http.statusCode)
            }
        }
        let response: ForecastResponse
        do {
            response = try decoder.decode(ForecastResponse.self, from: result.0)
        } catch {
            throw WeatherError.badResponse
        }
        return makeForecast(response, isApproximate: query == .here)
    }

    private static func makeForecast(_ response: ForecastResponse, isApproximate: Bool) -> Forecast {
        let location = response.location
        let current = response.current
        let timeZone = TimeZone(identifier: location.tzId) ?? .current

        // "2026-10-31" -> "Sam."; today is the first day of the local date.
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        parser.dateFormat = "yyyy-MM-dd"
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: Config.weatherLanguage)
        weekday.timeZone = timeZone
        weekday.dateFormat = "EEE"
        let today = String(location.localtime.prefix(10))

        let days = response.forecast.forecastday.map { day -> Forecast.Day in
            let name: String
            if day.date == today {
                name = "Auj."
            } else if let date = parser.date(from: day.date) {
                name = weekday.string(from: date).capitalized(with: weekday.locale)
            } else {
                name = day.date
            }
            return Forecast.Day(
                name: name,
                low: day.day.mintempC,
                high: day.day.maxtempC,
                condition: WeatherCondition(code: day.day.condition.code, isDay: true),
                rainChance: max(day.day.dailyChanceOfRain?.value ?? 0, day.day.dailyChanceOfSnow?.value ?? 0) / 100
            )
        }

        // Hours run on from the slot that contains the place's current time.
        let now = location.localtimeEpoch
        let allHours = response.forecast.forecastday.flatMap(\.hour)
        func chance(_ hour: ForecastResponse.Hour) -> Double {
            max(hour.chanceOfRain?.value ?? 0, hour.chanceOfSnow?.value ?? 0) / 100
        }
        let currentIndex = allHours.lastIndex { $0.timeEpoch <= now }
        // Independent of Config.weatherHours, so the current-conditions row
        // keeps it even when no hourly columns are shown.
        let rainChance = currentIndex.map { chance(allHours[$0]) }
        let upcoming = allHours[(currentIndex ?? allHours.startIndex)...].prefix(Config.weatherHours)

        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "H'h'"
        let hours = upcoming.enumerated().map { offset, hour in
            Forecast.Hour(
                name: offset == 0 ? "Maint." : clock.string(from: Date(timeIntervalSince1970: hour.timeEpoch)),
                temperature: hour.tempC,
                condition: WeatherCondition(code: hour.condition.code, isDay: hour.isDay != 0),
                rainChance: chance(hour)
            )
        }

        let place = [location.name, location.country]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return Forecast(
            place: place,
            isApproximate: isApproximate,
            temperature: current.tempC,
            feelsLike: current.feelslikeC,
            humidity: current.humidity,
            windKmh: current.windKph,
            windDegrees: current.windDegree,
            description: current.condition.text,
            condition: WeatherCondition(code: current.condition.code, isDay: current.isDay != 0),
            rainChance: rainChance,
            hours: hours,
            currentHourEnd: currentIndex.map { Date(timeIntervalSince1970: allHours[$0].timeEpoch + 3600) },
            days: days
        )
    }
}

// MARK: - Response models (only the fields used)

/// A 0...100 percentage, which older WeatherAPI responses sent as a string.
private struct Percent: Decodable, Sendable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else {
            value = Double(try container.decode(String.self)) ?? 0
        }
    }
}

private struct ErrorResponse: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        let code: Int
    }
    let error: Detail
}

private struct ForecastResponse: Decodable, Sendable {
    struct Condition: Decodable, Sendable {
        let text: String
        let code: Int
    }
    struct Location: Decodable, Sendable {
        let name: String
        let country: String
        /// e.g. "Europe/Paris".
        let tzId: String
        let localtimeEpoch: TimeInterval
        /// "2026-10-31 14:05", in the place's time zone.
        let localtime: String
    }
    struct Current: Decodable, Sendable {
        let tempC: Double
        let feelslikeC: Double
        let humidity: Double
        let windKph: Double
        let windDegree: Double?
        let isDay: Int
        let condition: Condition
    }
    struct Day: Decodable, Sendable {
        let maxtempC: Double
        let mintempC: Double
        /// Percentages, 0...100.
        let dailyChanceOfRain: Percent?
        let dailyChanceOfSnow: Percent?
        let condition: Condition
    }
    struct Hour: Decodable, Sendable {
        let timeEpoch: TimeInterval
        let tempC: Double
        let isDay: Int
        let condition: Condition
        let chanceOfRain: Percent?
        let chanceOfSnow: Percent?
    }
    struct ForecastDay: Decodable, Sendable {
        /// "2026-10-31", in the place's time zone.
        let date: String
        let day: Day
        let hour: [Hour]
    }
    struct Forecast: Decodable, Sendable {
        let forecastday: [ForecastDay]
    }
    let location: Location
    let current: Current
    let forecast: Forecast
}
