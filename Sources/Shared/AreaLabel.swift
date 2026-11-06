// AreaLabel.swift
//
// The text label of the areas under the launcher input (the calendar list,
// the pomodoro view): system font, truncated at the end, and the first to
// shrink when the row is too narrow.

import Cocoa

extension NSTextField {
    static func areaLabel(
        _ text: String = "", size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
