// MenuBarIconTests.swift
//
// The menu bar icon draws the sun, the bar and the gaps between them where
// they should be (Sources/App/MenuBarIcon.swift), as a template image.

import AppKit

@MainActor
enum MenuBarIconTests {
    static func run() {
        let image = MenuBarIcon.make()
        SelfTest.check("menu bar icon: template image", image.isTemplate)
        SelfTest.check("menu bar icon: 18 pt square", image.size == NSSize(width: 18, height: 18))

        // Drawn at 2x, like a Retina menu bar.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            SelfTest.check("menu bar icon: bitmap for drawing", false)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()

        // Points from the top left, as in MenuBarIcon.
        func alpha(_ x: Double, _ y: Double) -> Double {
            Double(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.alphaComponent ?? -1)
        }
        let points: [(String, Double, Double, Bool)] = [
            ("sun", 9, 4.5, true),
            ("gap above the bar", 9, 6.7, false),
            ("bar", 13, 9, true),
            ("caret cut out of the bar", 4.4, 9, false),
            ("text cut out of the bar", 7.8, 9, false),
            ("reflection", 9, 13.6, true),
            ("corner", 0.5, 0.5, false),
        ]
        for (name, x, y, filled) in points {
            let value = alpha(x, y)
            SelfTest.check("menu bar icon: \(name) is \(filled ? "drawn" : "clear")",
                           filled ? value > 0.9 : value >= 0 && value < 0.1, "alpha \(value)")
        }
    }
}
