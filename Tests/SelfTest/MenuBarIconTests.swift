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

        guard let bitmap = SelfTest.drawAt2x(image) else {
            SelfTest.check("menu bar icon: bitmap for drawing", false)
            return
        }
        // Points from the top left, as in MenuBarIcon.
        func alpha(_ x: Double, _ y: Double) -> Double { SelfTest.alpha(in: bitmap, x, y) }
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
