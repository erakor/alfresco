// TransitMenuBarIcon.swift
//
// The transit menu bar item's icon: SF Symbols' tram, and with `alert`, a
// dot in its top-right corner cut out of the tram, like a notification
// badge. A template image, so macOS tints it for light and dark menu bars
// and while the menu is open.

import AppKit

enum TransitMenuBarIcon {
    /// Points, like the other menu bar icons.
    static let size = NSSize(width: 18, height: 18)
    /// The dot's center and radius, from the top left.
    static let badgeCenter = CGPoint(x: 14.5, y: 4)
    static let badgeRadius: CGFloat = 3.25
    /// The clear ring around the dot, so it reads apart from the tram.
    static let badgeGap: CGFloat = 1.5

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
            let ring = badgeRadius + badgeGap
            cg.setBlendMode(.clear)
            cg.fillEllipse(in: CGRect(x: badgeCenter.x - ring, y: badgeCenter.y - ring, width: ring * 2, height: ring * 2))
            cg.setBlendMode(.normal)
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillEllipse(in: CGRect(
                x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                width: badgeRadius * 2, height: badgeRadius * 2
            ))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = alert ? "Trains, with a service alert" : "Trains"
        return image
    }
}
