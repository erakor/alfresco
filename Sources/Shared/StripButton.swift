// StripButton.swift
//
// A line in the strip above the launcher input (the weather on the right,
// the next meeting on the left): StripView, whose whole content is one
// StripButton, highlighted on hover, darker while pressed, and clicked when
// the button is released over it, like the command cards. It never becomes
// first responder, so the input keeps focus.

import Cocoa

/// Base of the strips above the input: the view is as wide as its content,
/// all of it clickable. A subclass builds its content in `build()` and
/// passes it to `install(_:help:)`.
class StripView: NSView {
    /// The content was clicked (on mouse up, inside it).
    var onClick: (() -> Void)? {
        get { button.onClick }
        set { button.onClick = newValue }
    }

    /// The whole view; subclasses set its tool tip and accessibility label.
    let button = StripButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Builds the content and calls install with it.
    func build() {}

    /// Makes `content` the strip's clickable content.
    func install(_ content: NSView, help: String) {
        button.install(content, in: self)
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp(help)
    }

    /// Forgets a hover or press, for when the panel closes: no exit event
    /// comes with it.
    func clearHover() { button.clearHover() }

    #if SELFTEST
    /// Clicks the content as the mouse would.
    func clickForSelfTest() { _ = button.accessibilityPerformPress() }
    #endif
}

final class StripButton: NSView {
    /// Height the strip adds above the launcher's input row.
    static let stripHeight: CGFloat = 24
    /// Room between the highlight's edge and the content. The launcher lays
    /// each strip out this much past the input row's edges, so the content
    /// lines up with the row and the highlight stays inside the panel.
    static let inset: CGFloat = 6

    var onClick: (() -> Void)?

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    /// Puts `content` in the button and the button in `strip`, which then
    /// hugs it: the strip is as wide as its content plus the insets.
    func install(_ content: NSView, in strip: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(self)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),

            leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            heightAnchor.constraint(equalToConstant: 18),
            // A little below the panel's top edge, clear of the rounded corner.
            centerYAnchor.constraint(equalTo: strip.centerYAnchor, constant: 3),
        ])
    }

    /// Forgets a hover or press, for when the panel closes: no exit event
    /// comes with it.
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
