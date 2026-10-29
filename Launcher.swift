// Launcher.swift
//
// A lightweight, Spotlight-style URL launcher for macOS.
//
// - Global hotkey via Carbon's RegisterEventHotKey: no Accessibility or
//   Screen Recording permission is required.
// - Runs as an accessory agent (no Dock icon). A small menu bar icon offers
//   "Open" and "Quit"; turn it off with Config.showMenuBarIcon.
//
// Build:  swiftc -O -parse-as-library Launcher.swift -o Launcher
// Run:    ./Launcher

import Cocoa
import Carbon.HIToolbox

// MARK: - Configuration

/// A system-wide shortcut registered through RegisterEventHotKey.
struct HotKey: Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    static let commandShiftSpace = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(cmdKey | shiftKey),
        display: "⌘⇧Space"
    )

    /// macOS 15 and later refuse hotkeys whose only modifiers are Option or
    /// Option+Shift, so this preset only works on macOS 14 and earlier.
    static let optionSpace = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey),
        display: "⌥Space"
    )
}

/// A keyword that expands into a URL. `{query}` in the template is replaced
/// with the percent-encoded argument.
struct Shortcut: Sendable {
    let keywords: [String]
    let title: String
    let urlTemplate: String
    var transform: @Sendable (String) -> String = { $0 }
}

enum Config {
    static let githubOwner = "your-org"
    static let githubRepo = "your-repo"

    static let hotKey = HotKey.commandShiftSpace
    static let showMenuBarIcon = true

    /// Add new commands here. Keywords are matched case-insensitively.
    static let shortcuts: [Shortcut] = [
        Shortcut(
            keywords: ["pr"],
            title: "GitHub PR",
            urlTemplate: "https://github.com/\(githubOwner)/\(githubRepo)/pull/{query}",
            transform: { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        ),
        Shortcut(
            keywords: ["jira"],
            title: "Jira",
            urlTemplate: "https://understood.atlassian.net/browse/{query}",
            transform: { $0.uppercased() }
        ),
        Shortcut(
            keywords: ["cf"],
            title: "Contentful entry",
            urlTemplate: "https://app.contentful.com/spaces/p0qf7j048i0q/entries/{query}"
        ),
    ]

    /// Used when no keyword matches, or a keyword is typed without an argument.
    static let fallback = Shortcut(
        keywords: [],
        title: "Search Google",
        urlTemplate: "https://www.google.com/search?q={query}"
    )
}

// MARK: - Command parsing

struct Command {
    let url: URL
    let label: String
}

enum CommandParser {
    /// RFC 3986 unreserved characters; everything else gets percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Parses `<keyword> <argument>`, falling back to a Google search.
    static func parse(_ raw: String) -> Command? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if parts.count == 2,
           let shortcut = Config.shortcuts.first(where: { $0.keywords.contains(parts[0].lowercased()) }) {
            let argument = shortcut.transform(parts[1].trimmingCharacters(in: .whitespaces))
            if !argument.isEmpty, let url = expand(shortcut.urlTemplate, with: argument) {
                return Command(url: url, label: "\(shortcut.title) \(argument)")
            }
        }

        guard let url = expand(Config.fallback.urlTemplate, with: input) else { return nil }
        return Command(url: url, label: Config.fallback.title)
    }

    private static func expand(_ template: String, with argument: String) -> URL? {
        guard let encoded = argument.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }
}

// MARK: - Global hotkey (Carbon)

/// Registers one system-wide hotkey. Carbon hotkeys are delivered through the
/// app's own event loop, so no privacy permission is involved.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: @MainActor @Sendable () -> Void

    init(onPress: @escaping @MainActor @Sendable () -> Void) {
        self.onPress = onPress
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    func register(_ hotKey: HotKey) -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().handlePress()
                return OSStatus(noErr)
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        guard installStatus == OSStatus(noErr) else { return false }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("LNCH"), id: 1)
        let registerStatus = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registerStatus == OSStatus(noErr)
    }

    private func handlePress() {
        let onPress = self.onPress
        Task { @MainActor in onPress() }
    }
}

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}

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

// MARK: - Launcher window

@MainActor
final class LauncherController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private enum Layout {
        static let width: CGFloat = 680
        static let height: CGFloat = 60
        static let cornerRadius: CGFloat = 14
        /// How far above the screen's vertical center the bar sits, as a
        /// fraction of the screen height. Set to 0 for dead center.
        static let verticalOffset: CGFloat = 0.15
    }

    private let panel: LauncherPanel
    private let textField = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "")
    private var isHiding = false

    override init() {
        panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        buildContent()
    }

    // MARK: Showing and hiding

    func toggle() {
        if panel.isVisible && !isHiding {
            hide()
        } else {
            show()
        }
    }

    func show() {
        isHiding = false
        let target = targetFrame()

        textField.stringValue = ""
        updateHint()

        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: -8), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)

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
        textField.stringValue = ""
    }

    private func execute() {
        guard let command = CommandParser.parse(textField.stringValue) else {
            hide()
            return
        }
        NSWorkspace.shared.open(command.url)
        textField.stringValue = ""
        hide()
    }

    private func updateHint() {
        if let command = CommandParser.parse(textField.stringValue) {
            hintLabel.stringValue = "↩ \(command.label)"
        } else {
            hintLabel.stringValue = "esc to close"
        }
    }

    /// Centers the bar on the screen that holds the mouse pointer.
    private func targetFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.midX - Layout.width / 2
        let y = visible.midY - Layout.height / 2 + visible.height * Layout.verticalOffset
        return NSRect(x: x, y: y, width: Layout.width, height: Layout.height).integral
    }

    // MARK: NSWindowDelegate

    /// Clicking anywhere outside the panel moves key focus elsewhere.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateHint()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            execute()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
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

    private func buildContent() {
        // .popover adapts to light and dark mode; try .hudWindow for an
        // always-dark bar or .fullScreenUI for a thinner, more see-through one.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = roundedMaskImage(radius: Layout.cornerRadius)
        panel.contentView = background

        // Hairline edge, added first so it never intercepts clicks.
        let border = NSView()
        border.wantsLayer = true
        border.layer?.cornerRadius = Layout.cornerRadius
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 1
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 24, weight: .light)
        textField.placeholderString = "Search Google, or type pr, jira, cf…"
        textField.cell?.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.delegate = self
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        for view in [border, icon, textField, hintLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }

        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            border.topAnchor.constraint(equalTo: background.topAnchor),
            border.bottomAnchor.constraint(equalTo: background.bottomAnchor),

            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            textField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            textField.centerYAnchor.constraint(equalTo: background.centerYAnchor),

            hintLabel.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            hintLabel.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcher: LauncherController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launcher = LauncherController()
        self.launcher = launcher

        let manager = HotKeyManager { [weak launcher] in launcher?.toggle() }
        hotKeyManager = manager

        if Config.showMenuBarIcon {
            setUpStatusItem()
        }
        if !manager.register(Config.hotKey) {
            showHotKeyError()
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Launcher")

        let menu = NSMenu()
        let open = NSMenuItem(
            title: "Open Launcher (\(Config.hotKey.display))",
            action: #selector(openLauncher),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    @objc private func openLauncher() {
        launcher?.show()
    }

    private func showHotKeyError() {
        let alert = NSAlert()
        alert.messageText = "Could not register \(Config.hotKey.display)"
        alert.informativeText = """
            Another app may already use this shortcut, or macOS rejected it. \
            Change Config.hotKey in Launcher.swift and rebuild.
            """
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        alert.runModal()
    }
}

@main
enum LauncherApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
