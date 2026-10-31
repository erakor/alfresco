// Launcher.swift
//
// A lightweight, Spotlight-style URL launcher for macOS, with a 24-hour
// clipboard history (ClipboardHistory.swift, ClipboardPanel.swift).
//
// - Global hotkeys via Carbon's RegisterEventHotKey: no Accessibility or
//   Screen Recording permission is required.
// - Runs as an accessory agent (no Dock icon). A small menu bar icon offers
//   "Open", "Clipboard History", "Edit Workflows…" and "Quit"; turn it off
//   with Config.showMenuBarIcon.
// - Workflows (keyword -> URL) live in workflows.json next to this file and
//   are reloaded automatically, so adding one needs no rebuild.
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

enum Config {
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
    /// Images larger than this, once encoded as PNG, are not recorded.
    static let clipboardMaxImageBytes = 20 * 1024 * 1024
    /// macOS has no clipboard-change notification, so the clipboard's change
    /// counter is checked this often (in seconds). The check itself is cheap.
    static let clipboardPollInterval: TimeInterval = 0.5

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

    /// The workflow whose keyword is the whole input, when it still needs an
    /// argument (e.g. just "pr"). Enter does nothing then, and the hint shows
    /// the workflow's help instead.
    func workflowAwaitingArgument(_ input: String) -> Workflow? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workflow = workflow(for: input), workflow.takesArgument else { return nil }
        return workflow
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

// MARK: - Launcher window

@MainActor
final class LauncherController: FloatingPanelController, NSTextFieldDelegate {
    private let store: WorkflowStore
    private let textField = NSTextField()
    private let hintLabel = FloatingPanelController.makeHintLabel()
    /// Text to start with on the next show(prefill:).
    private var pendingPrefill = ""

    init(store: WorkflowStore) {
        self.store = store
        super.init(size: NSSize(width: 680, height: 60), verticalOffset: 0.15)
        buildContent()
    }

    override var initialFirstResponder: NSResponder? { textField }

    /// Opens the bar, optionally with text already typed (cursor at the end).
    func show(prefill: String) {
        pendingPrefill = prefill
        show()
    }

    override func prepareToShow() {
        store.reloadIfNeeded()
        textField.placeholderString = placeholder()
        textField.stringValue = pendingPrefill
        pendingPrefill = ""
        updateHint()
    }

    override func didFocus() {
        let end = (textField.stringValue as NSString).length
        textField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    override func didHide() {
        textField.stringValue = ""
    }

    private func execute() {
        // Keyword typed without its argument: keep the bar open and wait.
        if store.current.workflowAwaitingArgument(textField.stringValue) != nil { return }
        guard let command = CommandParser.parse(textField.stringValue, using: store.current) else {
            hide()
            return
        }
        NSWorkspace.shared.open(command.url)
        textField.stringValue = ""
        hide()
    }

    private func updateHint() {
        if let workflow = store.current.workflowAwaitingArgument(textField.stringValue) {
            // The keyword is typed but its argument is not: show its help.
            let keyword = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let help = workflow.help ?? "\(workflow.title): type a value after \"\(keyword)\""
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

        Self.styleSearchField(textField, placeholder: placeholder())
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
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let workflowStore = WorkflowStore()
    private var launcher: LauncherController?
    private var clipboardStore: ClipboardStore?
    private var clipboardMonitor: ClipboardMonitor?
    private var clipboardPanel: ClipboardController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launcher = LauncherController(store: workflowStore)
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
        let workflows = NSMenuItem(title: "Workflows", action: nil, keyEquivalent: "")
        let workflowsMenu = NSMenu(title: "Workflows")
        workflowsMenu.delegate = self
        workflows.submenu = workflowsMenu
        menu.addItem(workflows)
        menu.addItem(menuItem("Edit Workflows…", #selector(editWorkflows)))
        menu.addItem(menuItem("Show Workflows in Finder", #selector(revealWorkflows)))
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

    // MARK: NSMenuDelegate

    /// Rebuilds the Workflows submenu each time it opens, so it always
    /// matches workflows.json.
    func menuNeedsUpdate(_ menu: NSMenu) {
        workflowStore.reloadIfNeeded()
        menu.removeAllItems()

        let workflows = workflowStore.current.workflows
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
        let takesArgument = workflowStore.current.workflow(for: keyword)?.takesArgument ?? false
        launcher?.show(prefill: takesArgument ? keyword + " " : keyword)
    }

    /// Opens workflows.json in the default editor for JSON files. Changes are
    /// picked up the next time the launcher opens.
    @objc private func editWorkflows() {
        workflowStore.ensureFileExists()
        NSWorkspace.shared.open(workflowStore.fileURL)
    }

    @objc private func revealWorkflows() {
        workflowStore.ensureFileExists()
        NSWorkspace.shared.activateFileViewerSelecting([workflowStore.fileURL])
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
