// Launcher.swift
//
// A lightweight, Spotlight-style URL launcher for macOS, with a 24-hour
// clipboard history (ClipboardHistory.swift, ClipboardPanel.swift).
//
// - Global hotkeys via Carbon's RegisterEventHotKey: no Accessibility or
//   Screen Recording permission is required.
// - Runs as an accessory agent (no Dock icon). A small menu bar icon offers
//   "Open", "Clipboard History" and "Quit"; turn it off with
//   Config.showMenuBarIcon.
//
// Build:  swiftc -O -parse-as-library *.swift -o Launcher
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

    /// Overrides ⌘⌥C inside apps while the launcher runs (Finder's "Copy as
    /// Pathname", the browsers' web inspector).
    static let commandOptionC = HotKey(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(cmdKey | optionKey),
        display: "⌘⌥C"
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

    /// Opens the clipboard history panel.
    static let clipboardHotKey = HotKey.commandOptionC
    /// Copied items older than this are deleted, from memory and from disk.
    static let clipboardRetention: TimeInterval = 24 * 60 * 60
    /// Oldest items are dropped beyond this count.
    static let clipboardMaxItems = 500
    /// Larger copies are not recorded.
    static let clipboardMaxTextBytes = 256 * 1024
    /// macOS has no clipboard-change notification, so the clipboard's change
    /// counter is checked this often (in seconds). The check itself is cheap.
    static let clipboardPollInterval: TimeInterval = 0.5

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


// MARK: - Global hotkeys (Carbon)

/// Registers system-wide hotkeys. Carbon hotkeys are delivered through the
/// app's own event loop, so no privacy permission is involved.
final class HotKeyManager {
    typealias Action = @MainActor @Sendable () -> Void

    private static let signature = fourCharCode("LNCH")

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: Action] = [:]
    private var nextID: UInt32 = 1

    deinit {
        for hotKeyRef in hotKeyRefs { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Returns false when macOS refuses the shortcut (usually because another
    /// app already registered it).
    func register(_ hotKey: HotKey, action: @escaping Action) -> Bool {
        guard installHandlerIfNeeded() else { return false }

        let id = nextID
        nextID += 1

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == OSStatus(noErr), let hotKeyRef else { return false }

        hotKeyRefs.append(hotKeyRef)
        actions[id] = action
        return true
    }

    /// One Carbon handler serves every hotkey; it tells them apart by the
    /// EventHotKeyID each one was registered with.
    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == OSStatus(noErr) else { return status }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handlePress(hotKeyID)
                    ? OSStatus(noErr)
                    : OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        return status == OSStatus(noErr)
    }

    private func handlePress(_ hotKeyID: EventHotKeyID) -> Bool {
        guard hotKeyID.signature == Self.signature, let action = actions[hotKeyID.id] else {
            return false
        }
        Task { @MainActor in action() }
        return true
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

// MARK: - Launcher window

@MainActor
final class LauncherController: FloatingPanelController, NSTextFieldDelegate {
    private let textField = NSTextField()
    private let hintLabel = FloatingPanelController.makeHintLabel()

    init() {
        super.init(size: NSSize(width: 680, height: 60), verticalOffset: 0.15)
        buildContent()
    }

    override var initialFirstResponder: NSResponder? { textField }

    override func prepareToShow() {
        textField.stringValue = ""
        updateHint()
    }

    override func didHide() {
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

    private func buildContent() {
        let icon = Self.makeIcon(symbolName: "magnifyingglass")

        Self.styleSearchField(textField, placeholder: "Search Google, or type pr, jira, cf…")
        textField.delegate = self

        hintLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        for view in [icon, textField, hintLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            textField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            textField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            hintLabel.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            hintLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcher: LauncherController?
    private var clipboardStore: ClipboardStore?
    private var clipboardMonitor: ClipboardMonitor?
    private var clipboardPanel: ClipboardController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launcher = LauncherController()
        self.launcher = launcher

        let store = ClipboardStore()
        let monitor = ClipboardMonitor(store: store)
        let clipboardPanel = ClipboardController(store: store, monitor: monitor)
        clipboardStore = store
        clipboardMonitor = monitor
        self.clipboardPanel = clipboardPanel
        monitor.start()

        if Config.showMenuBarIcon {
            setUpStatusItem()
        }

        let manager = HotKeyManager()
        hotKeyManager = manager

        var failed: [HotKey] = []
        if !manager.register(Config.hotKey, action: { [weak launcher] in launcher?.toggle() }) {
            failed.append(Config.hotKey)
        }
        if !manager.register(Config.clipboardHotKey, action: { [weak clipboardPanel] in clipboardPanel?.toggle() }) {
            failed.append(Config.clipboardHotKey)
        }
        if !failed.isEmpty {
            showHotKeyError(failed)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardStore?.saveNow()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Launcher")

        let menu = NSMenu()
        menu.addItem(menuItem("Open Launcher (\(Config.hotKey.display))", #selector(openLauncher)))
        menu.addItem(menuItem("Clipboard History (\(Config.clipboardHotKey.display))", #selector(openClipboardHistory)))
        menu.addItem(menuItem("Clear Clipboard History", #selector(clearClipboardHistory)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openLauncher() {
        launcher?.show()
    }

    @objc private func openClipboardHistory() {
        clipboardPanel?.show()
    }

    @objc private func clearClipboardHistory() {
        clipboardStore?.clear()
    }

    private func showHotKeyError(_ hotKeys: [HotKey]) {
        let names = hotKeys.map(\.display).joined(separator: " and ")
        let alert = NSAlert()
        alert.messageText = "Could not register \(names)"
        alert.informativeText = """
            Another app may already use \(hotKeys.count == 1 ? "this shortcut" : "these shortcuts"), \
            or macOS rejected \(hotKeys.count == 1 ? "it" : "them"). Change Config.hotKey or \
            Config.clipboardHotKey in Launcher.swift and rebuild.
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
