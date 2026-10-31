// Launcher.swift
//
// A lightweight, Spotlight-style URL launcher for macOS.
//
// - Global hotkey via Carbon's RegisterEventHotKey: no Accessibility or
//   Screen Recording permission is required.
// - Runs as an accessory agent (no Dock icon). A small menu bar icon offers
//   "Open", "Edit Workflows…" and "Quit"; turn it off with
//   Config.showMenuBarIcon.
// - Workflows (keyword -> URL) live in workflows.json next to this file and
//   are reloaded automatically, so adding one needs no rebuild.
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

enum Config {
    static let hotKey = HotKey.commandShiftSpace
    static let showMenuBarIcon = true

    /// Where workflows.json is read from, first match wins:
    /// 1. the `ALFRESCO_WORKFLOWS` environment variable;
    /// 2. the `AlfrescoWorkflowsFile` Info.plist key, which build.sh sets to
    ///    the repo's workflows.json;
    /// 3. workflows.json next to the executable (a plain binary built in the
    ///    repo);
    /// 4. ~/.config/alfresco/workflows.json, created on first launch.
    /// The file is re-read whenever it changes, so no rebuild is needed.
    static let workflowsSource: (url: URL, isFallback: Bool) = {
        let fileManager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["ALFRESCO_WORKFLOWS"], !path.isEmpty {
            return (URL(fileURLWithPath: (path as NSString).expandingTildeInPath), false)
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "AlfrescoWorkflowsFile") as? String, !path.isEmpty {
            return (URL(fileURLWithPath: (path as NSString).expandingTildeInPath), false)
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("workflows.json")
            if fileManager.fileExists(atPath: sibling.path) { return (sibling, false) }
        }
        let home = fileManager.homeDirectoryForCurrentUser
        return (home.appendingPathComponent(".config/alfresco/workflows.json"), true)
    }()

    /// Used until workflows.json loads, and to seed the ~/.config fallback.
    /// The real workflows live in the repo's workflows.json.
    static let defaultWorkflowsJSON = #"""
        {
          "workflows": [],
          "fallback": {
            "title": "Search Google",
            "url": "https://www.google.com/search?q={query}"
          }
        }

        """#
}

// MARK: - Workflows

/// A step applied to the argument before it is put into the URL. Written in
/// JSON as a string: "uppercase", "lowercase", "trim",
/// "stripPrefix:<text>" or "stripSuffix:<text>".
enum ArgumentTransform: Decodable, Sendable {
    case uppercase
    case lowercase
    case trim
    case stripPrefix(String)
    case stripSuffix(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        var name = raw
        var value = ""
        if let colon = raw.firstIndex(of: ":") {
            name = String(raw[..<colon])
            value = String(raw[raw.index(after: colon)...])
        }

        switch (name, value.isEmpty) {
        case ("uppercase", true): self = .uppercase
        case ("lowercase", true): self = .lowercase
        case ("trim", true): self = .trim
        case ("stripPrefix", false): self = .stripPrefix(value)
        case ("stripSuffix", false): self = .stripSuffix(value)
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown transform \"\(raw)\" (use uppercase, lowercase, trim, stripPrefix:<text> or stripSuffix:<text>)"
            )
        }
    }

    func apply(to value: String) -> String {
        switch self {
        case .uppercase: return value.uppercased()
        case .lowercase: return value.lowercased()
        case .trim: return value.trimmingCharacters(in: .whitespaces)
        case .stripPrefix(let prefix): return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
        case .stripSuffix(let suffix): return value.hasSuffix(suffix) ? String(value.dropLast(suffix.count)) : value
        }
    }
}

/// A keyword that expands into a URL. `{query}` in `url` is replaced with the
/// percent-encoded argument; a `url` without `{query}` is opened by typing
/// the keyword alone. `description` is optional help text.
struct Workflow: Decodable, Sendable {
    let keywords: [String]
    let title: String
    let url: String
    /// Shown while the keyword is typed without its argument, and in the
    /// menu bar's Workflows submenu. Written as "description" in JSON.
    let help: String?
    let transforms: [ArgumentTransform]

    var takesArgument: Bool { url.contains("{query}") }

    private enum CodingKeys: String, CodingKey {
        case keywords, title, url, transforms
        case help = "description"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)?
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        help = try container.decodeIfPresent(String.self, forKey: .help)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        transforms = try container.decodeIfPresent([ArgumentTransform].self, forKey: .transforms) ?? []

        if keywords.contains(where: { $0.isEmpty || $0.contains(where: \.isWhitespace) }) {
            throw DecodingError.dataCorruptedError(
                forKey: .keywords, in: container,
                debugDescription: "keywords must be single words"
            )
        }
    }

    func prepare(_ argument: String) -> String {
        transforms.reduce(argument) { $1.apply(to: $0) }
    }
}

struct WorkflowSet: Decodable, Sendable {
    let workflows: [Workflow]
    let fallback: Workflow

    private enum CodingKeys: String, CodingKey { case workflows, fallback }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflows = try container.decode([Workflow].self, forKey: .workflows)
        fallback = try container.decodeIfPresent(Workflow.self, forKey: .fallback) ?? Self.builtIn.fallback

        if let index = workflows.firstIndex(where: { $0.keywords.isEmpty }) {
            throw DecodingError.dataCorruptedError(
                forKey: .workflows, in: container,
                debugDescription: "workflow #\(index + 1) (\(workflows[index].title)) has no keywords"
            )
        }
        if !fallback.takesArgument {
            throw DecodingError.dataCorruptedError(
                forKey: .fallback, in: container,
                debugDescription: "fallback url must contain {query}"
            )
        }
    }

    // swiftlint:disable:next force_try
    static let builtIn = try! JSONDecoder().decode(WorkflowSet.self, from: Data(Config.defaultWorkflowsJSON.utf8))

    func workflow(for keyword: String) -> Workflow? {
        let keyword = keyword.lowercased()
        return workflows.first { $0.keywords.contains(keyword) }
    }
}

/// Owns workflows.json: finds it, reloads it when its modification date
/// changes, and keeps the last good version if an edit breaks it. Only used
/// from the main thread.
final class WorkflowStore {
    let fileURL: URL
    /// Only the ~/.config fallback is created when missing; a configured path
    /// that has gone missing is reported instead of silently recreated.
    private let createsMissingFile: Bool
    private(set) var current = WorkflowSet.builtIn
    /// Why the file on disk could not be used, if it could not.
    private(set) var loadError: String?
    private var loadedModificationDate: Date?

    init(fileURL: URL = Config.workflowsSource.url, createsMissingFile: Bool = Config.workflowsSource.isFallback) {
        self.fileURL = fileURL
        self.createsMissingFile = createsMissingFile
        reloadIfNeeded()
    }

    /// Writes the default file if it is the ~/.config fallback and missing.
    func ensureFileExists() {
        let fileManager = FileManager.default
        guard createsMissingFile, !fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(Config.defaultWorkflowsJSON.utf8).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Launcher: could not create %@: %@", fileURL.path, error.localizedDescription)
        }
    }

    /// Cheap enough to call every time the launcher opens: it only parses the
    /// file when its modification date differs from the last load.
    func reloadIfNeeded() {
        ensureFileExists()
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modified = attributes?[.modificationDate] as? Date
        guard modified == nil || modified != loadedModificationDate else { return }
        loadedModificationDate = modified

        do {
            let data = try Data(contentsOf: fileURL)
            current = try JSONDecoder().decode(WorkflowSet.self, from: data)
            loadError = nil
        } catch {
            loadError = Self.describe(error)
            NSLog("Launcher: ignoring %@: %@", fileURL.path, loadError ?? "")
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func location(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
            }.joined()
            return path.isEmpty ? "" : " at \(path)"
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \"\(key.stringValue)\"\(location(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(context.debugDescription)\(location(context))"
        case .dataCorrupted(let context):
            if let underlying = context.underlyingError as NSError?,
               let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                return detail
            }
            return "\(context.debugDescription)\(location(context))"
        @unknown default:
            return error.localizedDescription
        }
    }
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

    /// Parses `<keyword> [argument]`, falling back to the fallback workflow.
    static func parse(_ raw: String, using set: WorkflowSet) -> Command? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if let workflow = set.workflow(for: String(parts[0])) {
            if workflow.takesArgument, parts.count == 2 {
                let argument = workflow.prepare(parts[1].trimmingCharacters(in: .whitespaces))
                if !argument.isEmpty, let url = expand(workflow.url, with: argument) {
                    return Command(url: url, label: "\(workflow.title) \(argument)")
                }
            } else if !workflow.takesArgument, parts.count == 1, let url = URL(string: workflow.url) {
                return Command(url: url, label: workflow.title)
            }
        }

        guard let url = expand(set.fallback.url, with: set.fallback.prepare(input)) else { return nil }
        return Command(url: url, label: set.fallback.title)
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
    private let store: WorkflowStore
    private let textField = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "")
    private var isHiding = false

    init(store: WorkflowStore) {
        self.store = store
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

    /// Opens the bar, optionally with text already typed (cursor at the end).
    func show(prefill: String = "") {
        isHiding = false
        let target = targetFrame()

        store.reloadIfNeeded()
        textField.placeholderString = placeholder()
        textField.stringValue = prefill
        updateHint()

        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: -8), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
        textField.currentEditor()?.selectedRange = NSRange(location: (prefill as NSString).length, length: 0)

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
        guard let command = CommandParser.parse(textField.stringValue, using: store.current) else {
            hide()
            return
        }
        NSWorkspace.shared.open(command.url)
        textField.stringValue = ""
        hide()
    }

    private func updateHint() {
        let input = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let workflow = store.current.workflow(for: input), workflow.takesArgument {
            // The keyword is typed but its argument is not: show its help.
            let help = workflow.help ?? "\(workflow.title): type a value after \"\(input.lowercased())\""
            hintLabel.stringValue = help
            hintLabel.toolTip = help
        } else if let command = CommandParser.parse(textField.stringValue, using: store.current) {
            hintLabel.stringValue = "↩ \(command.label)"
            hintLabel.toolTip = nil
        } else if let error = store.loadError {
            hintLabel.stringValue = "⚠ workflows.json: \(error)"
            hintLabel.toolTip = "\(store.fileURL.path)\n\(error)"
        } else {
            hintLabel.stringValue = "esc to close"
            hintLabel.toolTip = nil
        }
    }

    private func placeholder() -> String {
        let set = store.current
        let keywords = set.workflows.compactMap(\.keywords.first).prefix(4)
        guard !keywords.isEmpty else { return set.fallback.title }
        return "\(set.fallback.title), or type \(keywords.joined(separator: ", "))…"
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
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = WorkflowStore()
    private var launcher: LauncherController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launcher = LauncherController(store: store)
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
        let workflows = NSMenuItem(title: "Workflows", action: nil, keyEquivalent: "")
        let workflowsMenu = NSMenu(title: "Workflows")
        workflowsMenu.delegate = self
        workflows.submenu = workflowsMenu
        menu.addItem(workflows)
        let edit = NSMenuItem(title: "Edit Workflows…", action: #selector(editWorkflows), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        let reveal = NSMenuItem(title: "Show Workflows in Finder", action: #selector(revealWorkflows), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    @objc private func openLauncher() {
        launcher?.show()
    }

    // MARK: NSMenuDelegate

    /// Rebuilds the Workflows submenu each time it opens, so it always
    /// matches workflows.json.
    func menuNeedsUpdate(_ menu: NSMenu) {
        store.reloadIfNeeded()
        menu.removeAllItems()

        let workflows = store.current.workflows
        if workflows.isEmpty {
            let empty = NSMenuItem(title: "No workflows yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for workflow in workflows {
            let item = NSMenuItem(
                title: "\(workflow.keywords.joined(separator: ", "))  \(workflow.title)",
                action: #selector(startWorkflow(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = workflow.keywords.first
            if let help = workflow.help {
                if #available(macOS 14.4, *) {
                    item.subtitle = help
                } else {
                    item.toolTip = help
                }
            }
            menu.addItem(item)
        }
    }

    /// Opens the launcher with the workflow's keyword already typed.
    @objc private func startWorkflow(_ sender: NSMenuItem) {
        guard let keyword = sender.representedObject as? String else { return }
        let takesArgument = store.current.workflow(for: keyword)?.takesArgument ?? false
        launcher?.show(prefill: takesArgument ? keyword + " " : keyword)
    }

    /// Opens workflows.json in the default editor for JSON files. Changes are
    /// picked up the next time the launcher opens.
    @objc private func editWorkflows() {
        store.ensureFileExists()
        NSWorkspace.shared.open(store.fileURL)
    }

    @objc private func revealWorkflows() {
        store.ensureFileExists()
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
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
