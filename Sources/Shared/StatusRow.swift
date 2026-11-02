// StatusRow.swift
//
// One line of status under the launcher input: a spinner or an SF Symbol,
// then secondary text. Shared by the weather forecast and the calendar
// list, so their loading and error states look the same.

import Cocoa

final class StatusRow: NSStackView {
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setViews([spinner, icon, label], in: .leading)
        orientation = .horizontal
        spacing = 8
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The spinner, then `text`.
    func showLoading(_ text: String) {
        spinner.isHidden = false
        spinner.startAnimation(nil)
        icon.isHidden = true
        setText(text)
    }

    /// An SF Symbol (a warning sign by default), then `text`.
    func showMessage(_ text: String, symbolName: String = "exclamationmark.triangle") {
        stopSpinner()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.isHidden = false
        setText(text)
    }

    /// Stops the spinner, e.g. when the content replaces the status.
    func stopSpinner() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
    }

    private func setText(_ text: String) {
        label.stringValue = text
        label.toolTip = text
    }
}
