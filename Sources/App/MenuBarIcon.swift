// MenuBarIcon.swift
//
// The menu bar version of the app icon (Resources/AppIcon.svg), as a line
// drawing: the sun's outline rising behind the search bar's, with the
// bar's caret. It is a template image, so macOS tints it for light and dark
// menu bars, and drawn in code, so the plain binary has it too.

import AppKit

enum MenuBarIcon {
    /// Points, like the SF Symbols the menu bar uses.
    static let size = NSSize(width: 18, height: 18)

    static func make() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setStrokeColor(NSColor.black.cgColor)
            cg.setLineWidth(1.2)
            cg.setLineCap(.round)

            // The search bar.
            let bar = CGRect(x: 1.1, y: 9.6, width: 15.8, height: 4.4)
            cg.addPath(CGPath(roundedRect: bar, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
            cg.strokePath()

            // The sun, cut where it meets the bar's top edge.
            cg.saveGState()
            cg.clip(to: CGRect(x: 0, y: 0, width: 18, height: bar.minY))
            cg.strokeEllipse(in: CGRect(x: 9 - 5.6, y: bar.minY - 5.6, width: 11.2, height: 11.2))
            cg.restoreGState()

            // The caret.
            cg.setLineWidth(1.1)
            cg.move(to: CGPoint(x: 4.65, y: 11))
            cg.addLine(to: CGPoint(x: 3.95, y: 12.6))
            cg.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Launcher"
        return image
    }
}
