// MenuBarIconTests.swift
//
// The menu bar icon draws the sun's and the bar's outlines and the caret
// where they should be (Sources/App/MenuBarIcon.swift), as a template image.

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
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            SelfTest.check("menu bar icon: bitmap for drawing", false)
            return
        }
        // 36 pixels for 18 points; without this the bitmap is 36 points and
        // the icon fills only a quarter of it. Set before the context is
        // made from the bitmap, which keeps the size it sees then.
        bitmap.size = image.size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
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
            ("sun outline", 9, 4, true),
            ("inside the sun", 9, 7, false),
            ("bar top edge", 13, 9.6, true),
            ("bar bottom edge", 9, 14, true),
            ("inside the bar", 10, 11.8, false),
            ("caret", 4.3, 11.8, true),
            ("beside the sun", 16, 7, false),
            ("corner", 0.5, 0.5, false),
        ]
        for (name, x, y, filled) in points {
            let value = alpha(x, y)
            SelfTest.check("menu bar icon: \(name) is \(filled ? "drawn" : "clear")",
                           filled ? value > 0.9 : value >= 0 && value < 0.1, "alpha \(value)")
        }
    }
}
