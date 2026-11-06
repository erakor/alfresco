// WeatherStripView.swift
//
// The weather in the launcher's top-right corner, above the input: the
// current weather at home (Config.weatherHomePlace, or the IP location) and
// today's high / low, right-aligned. Shown whenever a WeatherAPI key is set
// and Config.weatherStrip is on. Clicking it calls onClick (the launcher
// types `/weather`, which opens the forecast). The next meeting
// (MeetingStripView) can sit on the same line, on the left.

import Cocoa

final class WeatherStripView: StripView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")

    func show(_ state: WeatherState) {
        switch state {
        case .loading:
            icon.isHidden = true
            label.stringValue = "Météo…"
            label.textColor = .tertiaryLabelColor
            rangeLabel.stringValue = ""
            button.toolTip = nil
        case .failed(let message):
            icon.isHidden = true
            label.stringValue = message
            label.textColor = .tertiaryLabelColor
            rangeLabel.stringValue = ""
            button.toolTip = message + "\nCliquez pour les prévisions"
        case .loaded(let forecast):
            icon.isHidden = false
            icon.image = WeatherView.symbol(for: forecast.condition, pointSize: 14)
            let city = forecast.place.split(separator: ",").first.map(String.init) ?? forecast.place
            label.stringValue = "\(WeatherView.degrees(forecast.temperature))  \(forecast.description) · \(city)"
            label.textColor = .secondaryLabelColor
            if let today = forecast.days.first {
                rangeLabel.stringValue = "↑ \(WeatherView.degrees(today.high))  ↓ \(WeatherView.degrees(today.low))"
            } else {
                rangeLabel.stringValue = ""
            }
            var tip = forecast.place
            if forecast.isApproximate { tip += " (position approximative)" }
            button.toolTip = tip + "\nCliquez ou tapez \(CommandInput.typed(Config.weatherKeyword)) pour les prévisions"
        }
    }

    override func build() {
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rangeLabel.textColor = .tertiaryLabelColor
        rangeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Icon, text and high / low.
        let group = NSStackView(views: [icon, label, rangeLabel])
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 6
        group.setCustomSpacing(10, after: label)
        install(group, help: "Affiche les prévisions")
        button.setAccessibilityLabel("Météo")
    }
}
