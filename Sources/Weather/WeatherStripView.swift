// WeatherStripView.swift
//
// The weather in the launcher's top-right corner, above the input: the
// current weather at home (Config.weatherHomePlace, or the IP location) and
// today's high / low, right-aligned. Shown whenever a WeatherAPI key is set
// and Config.weatherStrip is on. Clicking it calls onClick (the launcher
// types `/weather`, which opens the forecast).

import Cocoa

final class WeatherStripView: NSView {
    /// Height the strip adds above the launcher's input row.
    static let height: CGFloat = 24
    /// Room between the click highlight's edge and the text. The launcher
    /// lays the strip out this much past the input row's right edge, so the
    /// text lines up with the row and the highlight stays inside the strip.
    static let highlightInset: CGFloat = 6

    /// The weather was clicked (on mouse up, inside it).
    var onClick: (() -> Void)? {
        get { button.onClick }
        set { button.onClick = newValue }
    }

    /// Only the weather itself takes clicks, not the empty strip to its left.
    private let button = StripButton()
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
        button.addSubview(group)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        let inset = Self.highlightInset
        NSLayoutConstraint.activate([
            group.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: inset),
            group.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -inset),
            group.centerYAnchor.constraint(equalTo: button.centerYAnchor),

            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            button.heightAnchor.constraint(equalToConstant: 18),
            // A little below the panel's top edge, clear of the rounded corner.
            button.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3),
        ])

        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("Météo")
        button.setAccessibilityHelp("Affiche les prévisions")
    }

    /// Forgets a hover or press, for when the panel closes: no exit event
    /// comes with it.
    func clearHover() { button.clearHover() }

    #if SELFTEST
    /// Clicks the weather as the mouse would.
    func clickForSelfTest() { _ = button.accessibilityPerformPress() }
    #endif
}

/// The clickable weather: highlighted on hover, darker while pressed, and
/// clicked when the button is released over it, like the command cards. It
/// never becomes first responder, so the input keeps focus.
private final class StripButton: NSView {
    var onClick: (() -> Void)?

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    func clearHover() {
        isHovered = false
        isPressed = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered || isPressed else { return }
        NSColor.labelColor.withAlphaComponent(isPressed ? 0.16 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    // The labels inside would otherwise take the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
