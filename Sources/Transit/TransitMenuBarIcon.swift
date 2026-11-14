// TransitMenuBarIcon.swift
//
// The transit menu bar item's icon: SF Symbols' tram, as a template image,
// so macOS tints it for light and dark menu bars and while the menu is
// open. With `alert`, a round hole is cut in its top-right corner, where
// TransitBadgeView puts an orange dot: a template image is one color, so
// the dot is a view on the status button rather than part of the image.

import AppKit

enum TransitMenuBarIcon {
    /// Points, like the other menu bar icons.
    static let size = NSSize(width: 18, height: 18)
    /// The dot's center and radius, from the image's top left.
    static let badgeCenter = CGPoint(x: 14.5, y: 4)
    static let badgeRadius: CGFloat = 3.25
    /// The clear ring around the dot, so it reads apart from the tram.
    static let badgeGap: CGFloat = 1.5
    /// The hole cut for the dot and its ring.
    static var holeRadius: CGFloat { badgeRadius + badgeGap }

    static func make(alert: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: true) { bounds in
            // Made here rather than captured: the handler may be called off
            // the main thread.
            let symbol = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            if let symbol, symbol.size.width > 0, symbol.size.height > 0 {
                // Its own proportions, centered, at most the icon's size.
                let scale = min(1, bounds.width / symbol.size.width, bounds.height / symbol.size.height)
                let width = symbol.size.width * scale
                let height = symbol.size.height * scale
                let rect = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
                symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            guard alert, let cg = NSGraphicsContext.current?.cgContext else { return true }
            let hole = holeRadius
            cg.setBlendMode(.clear)
            cg.fillEllipse(in: CGRect(x: badgeCenter.x - hole, y: badgeCenter.y - hole, width: hole * 2, height: hole * 2))
            cg.setBlendMode(.normal)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = alert ? "Trains, with a service alert" : "Trains"
        return image
    }
}

/// The orange dot over the icon's hole. Drawn in `draw(_:)` so the color
/// follows the menu bar's light or dark appearance.
final class TransitBadgeView: NSView {
    static let color = NSColor.systemOrange

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        let side = TransitMenuBarIcon.badgeRadius * 2
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Puts the dot over the hole of an 18 pt icon centered in `button`,
    /// as a status bar button shows its image.
    func place(in button: NSView) {
        button.addSubview(self)
        let icon = TransitMenuBarIcon.size
        let center = TransitMenuBarIcon.badgeCenter
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: center.x - icon.width / 2),
            // Layout anchors run top to bottom: negative is up.
            centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: center.y - icon.height / 2),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    // Clicks go to the status button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
