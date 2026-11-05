// MenuBarIcon.swift
//
// The menu bar version of the app icon (Resources/AppIcon.svg): the sun
// rising over the search bar, with its reflection in the sea below. A menu
// bar icon is one color, so the sun, the bar and the reflection are solid
// and kept apart by gaps, and the bar's caret and text are cut out of it.
// It is a template image, so macOS tints it for light and dark menu bars,
// and drawn in code, so the plain binary has it too.

import AppKit

enum MenuBarIcon {
    /// Points, like the SF Symbols the menu bar uses.
    static let size = NSSize(width: 18, height: 18)

    static func make() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // The cut-outs clear pixels, so they happen in a layer of their
            // own rather than in whatever the image is drawn onto.
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { cg.endTransparencyLayer() }
            cg.setFillColor(NSColor.black.cgColor)

            // The sun, cut at the horizon like the sea cuts it in the app icon.
            cg.saveGState()
            cg.clip(to: CGRect(x: 0, y: 0, width: 18, height: 9))
            cg.fillEllipse(in: CGRect(x: 3, y: 3, width: 12, height: 12))
            cg.restoreGState()

            // Its reflection.
            fill(cg, CGRect(x: 5.5, y: 13, width: 7, height: 1.2))
            fill(cg, CGRect(x: 7, y: 15.2, width: 4, height: 1.1))

            // A gap around the bar, then the bar.
            cg.setBlendMode(.clear)
            fill(cg, CGRect(x: 0.4, y: 6.4, width: 17.2, height: 5.2))
            cg.setBlendMode(.normal)
            fill(cg, CGRect(x: 1.5, y: 7, width: 15, height: 4))

            // The caret and the typed text, cut out of the bar.
            cg.setBlendMode(.clear)
            cg.setLineWidth(1.1)
            cg.setLineCap(.round)
            cg.move(to: CGPoint(x: 4.7, y: 7.9))
            cg.addLine(to: CGPoint(x: 4.1, y: 10.1))
            cg.strokePath()
            fill(cg, CGRect(x: 6.2, y: 8.4, width: 3.2, height: 1.2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Launcher"
        return image
    }

    /// A capsule: a rectangle with fully rounded ends.
    private static func fill(_ cg: CGContext, _ rect: CGRect) {
        let radius = min(rect.width, rect.height) / 2
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.fillPath()
    }
}
