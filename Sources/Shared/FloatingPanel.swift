// FloatingPanel.swift
//
// LauncherPanel and FloatingPanelController: the shared base for every
// floating panel (frosted background, positioning, fade, dismissal).

import Cocoa

// MARK: - Panel

/// Borderless panel that can take keyboard focus without activating the app,
/// so the app you were in stays frontmost (like Spotlight).
final class LauncherPanel: NSPanel {
    var onCancel: (@MainActor () -> Void)?

    /// Accessory apps have no Edit menu, so the standard editing shortcuts
    /// would otherwise do nothing in the text field.
    private static let editActions: [String: Selector] = [
        "x": #selector(NSText.cut(_:)),
        "c": #selector(NSText.copy(_:)),
        "v": #selector(NSText.paste(_:)),
        "a": #selector(NSText.selectAll(_:)),
        "z": Selector(("undo:")),
    ]

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let action = Self.editActions[key],
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A stretchable rounded-rect mask for NSVisualEffectView, which keeps the
/// blur and the window shadow clipped to the rounded corners.
private func roundedMaskImage(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

// MARK: - Floating panel controller

/// Shared behavior for the launcher bar and the clipboard history panel: a
/// frosted, non-activating panel on the screen under the mouse, with fade
/// animations, dismissed by Esc, by clicking elsewhere, or by its hotkey.
/// Subclasses add their views to `contentView`.
@MainActor
class FloatingPanelController: NSObject, NSWindowDelegate {
    static let cornerRadius: CGFloat = 14

    let panel: LauncherPanel
    /// Host for the subclass's views (the frosted background).
    let contentView = NSVisualEffectView()

    private let size: NSSize
    /// How far above the screen's vertical center the panel sits, as a
    /// fraction of the screen height. 0 is dead center.
    private let verticalOffset: CGFloat
    private var isHiding = false

    init(size: NSSize, verticalOffset: CGFloat) {
        self.size = size
        self.verticalOffset = verticalOffset
        panel = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        buildBackground()
    }

    // MARK: Subclass hooks

    /// Reset the content before the panel appears.
    func prepareToShow() {}

    /// Clean up after the panel has faded out.
    func didHide() {}

    /// Receives keyboard focus when the panel appears.
    var initialFirstResponder: NSResponder? { nil }

    /// Runs once `initialFirstResponder` has focus.
    func didFocus() {}

    // MARK: Showing and hiding

    var isShown: Bool { panel.isVisible && !isHiding }

    func toggle() {
        if isShown {
            hide()
        } else {
            show()
        }
    }

    func show() {
        isHiding = false
        let target = targetFrame()

        prepareToShow()

        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: -8), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(initialFirstResponder)
        didFocus()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        })
    }

    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in self.finishHide() }
        })
    }

    private func finishHide() {
        // show() ran while the fade-out was in flight; keep the panel up.
        guard isHiding else { return }
        isHiding = false
        panel.orderOut(nil)
        panel.alphaValue = 1
        didHide()
    }

    /// Centers the panel on the screen that holds the mouse pointer.
    private func targetFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + visible.height * verticalOffset
        return NSRect(x: x, y: y, width: size.width, height: size.height).integral
    }

    // MARK: NSWindowDelegate

    /// Clicking anywhere outside the panel moves key focus elsewhere.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: Setup

    private func configurePanel() {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
    }

    private func buildBackground() {
        // .popover adapts to light and dark mode; try .hudWindow for an
        // always-dark panel or .fullScreenUI for a thinner, more see-through one.
        contentView.material = .popover
        contentView.blendingMode = .behindWindow
        contentView.state = .active
        contentView.maskImage = roundedMaskImage(radius: Self.cornerRadius)
        panel.contentView = contentView

        // Hairline edge, added first so it never intercepts clicks.
        let border = NSView()
        border.wantsLayer = true
        border.layer?.cornerRadius = Self.cornerRadius
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 1
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(border)

        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            border.topAnchor.constraint(equalTo: contentView.topAnchor),
            border.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: Shared views

    static func makeIcon(symbolName: String) -> NSImageView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        return icon
    }

    static func styleSearchField(_ field: NSTextField, placeholder: String) {
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    static func makeHintLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
