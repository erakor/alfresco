// WeatherStripView.swift
//
// The weather in the launcher's top-right corner, above the input: the
// current weather at home (Config.weatherHomePlace, or the IP location) and
// today's high / low, right-aligned. Shown whenever a WeatherAPI key is set
// and Config.weatherStrip is on.

import Cocoa

final class WeatherStripView: NSView {
    /// Height the strip adds above the launcher's input row.
    static let height: CGFloat = 24

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

        // Icon, text and high / low, hugging the right edge.
        let group = NSStackView(views: [icon, label, rangeLabel])
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 6
        group.setCustomSpacing(10, after: label)
        group.translatesAutoresizingMaskIntoConstraints = false
        addSubview(group)

        NSLayoutConstraint.activate([
            group.trailingAnchor.constraint(equalTo: trailingAnchor),
            group.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            // A little below the panel's top edge, clear of the rounded corner.
            group.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3),
        ])
    }
}
