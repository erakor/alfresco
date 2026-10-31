// WeatherView.swift
//
// The forecast area under the launcher field: current conditions on top,
// five days below, plus loading and error states. Labels are in French, to
// match Config.weatherLanguage's default.

import Cocoa

final class WeatherView: NSView {
    /// Height the launcher adds below its input row while this is shown.
    static let height: CGFloat = 190

    // Current conditions
    private let icon = NSImageView()
    private let temperatureLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let placeLabel = NSTextField(labelWithString: "")
    private let detailsLabel = NSTextField(labelWithString: "")
    private let currentRow = NSView()

    // Days
    private let daysStack = NSStackView()
    private var dayColumns: [DayColumn] = []

    // Loading and error
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let statusStack = NSStackView()

    private let attribution = NSTextField(labelWithString: "Données : OpenWeather")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ state: WeatherState, for query: WeatherQuery) {
        switch state {
        case .loading:
            setContentVisible(false)
            spinner.isHidden = false
            spinner.startAnimation(nil)
            statusIcon.isHidden = true
            switch query {
            case .here: statusLabel.stringValue = "Météo autour de vous…"
            case .place(let place): statusLabel.stringValue = "Météo pour \(place)…"
            }
        case .failed(let message):
            setContentVisible(false)
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusIcon.isHidden = false
            statusLabel.stringValue = message
        case .loaded(let forecast):
            spinner.stopAnimation(nil)
            setContentVisible(true)
            fill(with: forecast)
        }
    }

    private func setContentVisible(_ visible: Bool) {
        currentRow.isHidden = !visible
        daysStack.isHidden = !visible
        statusStack.isHidden = visible
    }

    private func fill(with forecast: Forecast) {
        icon.image = Self.symbol(for: forecast.icon, pointSize: 40)
        temperatureLabel.stringValue = Self.degrees(forecast.temperature)
        descriptionLabel.stringValue = forecast.description.prefix(1).uppercased() + forecast.description.dropFirst()
        placeLabel.stringValue = forecast.isApproximate
            ? "\(forecast.place) · position approximative"
            : forecast.place

        var wind = "Vent \(Int(forecast.windKmh.rounded())) km/h"
        if let degrees = forecast.windDegrees { wind += " \(Self.windArrow(from: degrees))" }
        var second = [wind]
        if let rain = forecast.rainChance { second.append("Pluie \(Self.percent(rain)) d'ici 3 h") }
        detailsLabel.stringValue = [
            "Ressenti \(Self.degrees(forecast.feelsLike)) · Humidité \(Int(forecast.humidity.rounded())) %",
            second.joined(separator: " · "),
        ].joined(separator: "\n")

        for (index, column) in dayColumns.enumerated() {
            if index < forecast.days.count {
                column.isHidden = false
                column.fill(with: forecast.days[index])
            } else {
                column.isHidden = true
            }
        }
    }

    // MARK: Formatting

    static func degrees(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) %"
    }

    /// Arrow pointing where the wind blows to; `degrees` is where it comes from.
    static func windArrow(from degrees: Double) -> String {
        let arrows = ["↓", "↙", "←", "↖", "↑", "↗", "→", "↘"]
        let index = Int((degrees / 45).rounded()) % 8
        return arrows[(index + 8) % 8]
    }

    /// SF Symbol for an OpenWeather icon code ("01d", "10n", ...), in color.
    static func symbol(for code: String, pointSize: CGFloat) -> NSImage? {
        let night = code.hasSuffix("n")
        let name: String
        switch code.prefix(2) {
        case "01": name = night ? "moon.stars.fill" : "sun.max.fill"
        case "02": name = night ? "cloud.moon.fill" : "cloud.sun.fill"
        case "03": name = "cloud.fill"
        case "04": name = "smoke.fill"
        case "09": name = "cloud.drizzle.fill"
        case "10": name = night ? "cloud.moon.rain.fill" : "cloud.sun.rain.fill"
        case "11": name = "cloud.bolt.rain.fill"
        case "13": name = "cloud.snow.fill"
        case "50": name = "cloud.fog.fill"
        default: name = "cloud.fill"
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.preferringMulticolor())
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    // MARK: Setup

    private func build() {
        let separator = NSBox()
        separator.boxType = .separator

        temperatureLabel.font = .systemFont(ofSize: 36, weight: .light)
        descriptionLabel.font = .systemFont(ofSize: 15)
        placeLabel.font = .systemFont(ofSize: 12)
        placeLabel.textColor = .secondaryLabelColor
        placeLabel.lineBreakMode = .byTruncatingTail
        detailsLabel.font = .systemFont(ofSize: 12)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.alignment = .right
        detailsLabel.maximumNumberOfLines = 2
        attribution.font = .systemFont(ofSize: 10)
        attribution.textColor = .tertiaryLabelColor
        for label in [descriptionLabel, placeLabel, detailsLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let titles = NSStackView(views: [descriptionLabel, placeLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        for view in [icon, temperatureLabel, titles, detailsLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            currentRow.addSubview(view)
        }

        daysStack.orientation = .horizontal
        daysStack.distribution = .fillEqually
        daysStack.spacing = 8
        dayColumns = (0..<5).map { _ in DayColumn(frame: .zero) }
        for column in dayColumns { daysStack.addArrangedSubview(column) }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        statusIcon.contentTintColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusStack.setViews([spinner, statusIcon, statusLabel], in: .leading)
        statusStack.orientation = .horizontal
        statusStack.spacing = 8

        for view in [separator, currentRow, daysStack, statusStack, attribution] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            currentRow.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            currentRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            currentRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            currentRow.heightAnchor.constraint(equalToConstant: 48),

            icon.leadingAnchor.constraint(equalTo: currentRow.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: currentRow.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),

            temperatureLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            temperatureLabel.centerYAnchor.constraint(equalTo: currentRow.centerYAnchor),

            titles.leadingAnchor.constraint(equalTo: temperatureLabel.trailingAnchor, constant: 14),
            titles.centerYAnchor.constraint(equalTo: currentRow.centerYAnchor),

            detailsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titles.trailingAnchor, constant: 12),
            detailsLabel.trailingAnchor.constraint(equalTo: currentRow.trailingAnchor),
            detailsLabel.centerYAnchor.constraint(equalTo: currentRow.centerYAnchor),

            daysStack.topAnchor.constraint(equalTo: currentRow.bottomAnchor, constant: 14),
            daysStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            daysStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            statusStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            statusStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            attribution.trailingAnchor.constraint(equalTo: trailingAnchor),
            attribution.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }
}

/// One day: name, icon, high / low, and the chance of rain when it matters.
private final class DayColumn: NSStackView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let rangeLabel = NSTextField(labelWithString: "")
    private let rainLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .centerX
        spacing = 4

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        rainLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        rainLabel.textColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])
        setViews([nameLabel, icon, rangeLabel, rainLabel], in: .top)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func fill(with day: Forecast.Day) {
        nameLabel.stringValue = day.name
        icon.image = WeatherView.symbol(for: day.icon, pointSize: 20)
        rangeLabel.stringValue = "\(WeatherView.degrees(day.high)) / \(WeatherView.degrees(day.low))"
        // Kept in the layout (blank) so the columns stay aligned.
        rainLabel.stringValue = day.rainChance >= 0.2 ? "💧 \(WeatherView.percent(day.rainChance))" : " "
    }
}
