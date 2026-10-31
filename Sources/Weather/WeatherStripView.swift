// WeatherStripView.swift
//
// The one-line weather strip at the top of the launcher, above the input:
// the current weather at home (Config.weatherHomePlace, or the IP location)
// on the left, today's high / low on the right. Shown whenever a WeatherAPI
// key is set and Config.weatherStrip is on.

import Cocoa

final class WeatherStripView: NSView {
    /// Height the strip adds above the launcher's input row.
    static let height: CGFloat = 30

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ state: WeatherState) {
        switch state {
        case .loading:
            icon.isHidden = true
            label.stringValue = "Météo…"
            label.textColor = .tertiaryLabelColor
            rangeLabel.stringValue = ""
            toolTip = nil
        case .failed(let message):
            icon.isHidden = true
            label.stringValue = message
            label.textColor = .tertiaryLabelColor
            rangeLabel.stringValue = ""
            toolTip = message
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
            toolTip = tip + "\nTapez \"\(Config.weatherKeyword)\" pour les prévisions"
        }
    }

    private func build() {
        icon.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rangeLabel.textColor = .tertiaryLabelColor
        rangeLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Hairline between the strip and the input row.
        let separator = NSBox()
        separator.boxType = .separator

        for view in [icon, label, rangeLabel, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            // Lined up with the launcher's magnifying glass (24 pt wide).
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            rangeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            rangeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            rangeLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
