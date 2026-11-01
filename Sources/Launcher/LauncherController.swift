// LauncherController.swift
//
// The launcher panel: input field, hint line, and Enter handling, which
// opens a workflow's URL or an installed app.

import Carbon.HIToolbox
import Cocoa

// MARK: - Launcher window

@MainActor
final class LauncherController: FloatingPanelController, NSTextFieldDelegate {
    private let store: WorkflowStore
    private let textField = NSTextField()
    private let hintLabel = FloatingPanelController.makeHintLabel()
    private let icon = FloatingPanelController.makeIcon(symbolName: "magnifyingglass")
    /// Shown in place of an app's icon when the input names no app.
    private let searchIcon = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    private let apps = AppIndex()
    private let previews = PreviewFetcher()
    private let weather = WeatherProvider()
    private let weatherView = WeatherView(frame: .zero)
    private let weatherStrip = WeatherStripView(frame: .zero)
    /// The input row (icon, field, hint); moves down when the strip is shown.
    private let rowGuide = NSLayoutGuide()
    private var rowTop: NSLayoutConstraint?
    /// Height of the input row, which is the whole panel without the weather.
    private static let rowHeight: CGFloat = 60
    /// Text to start with on the next show(prefill:).
    private var pendingPrefill = ""

    init(store: WorkflowStore) {
        self.store = store
        super.init(size: NSSize(width: 680, height: LauncherController.rowHeight), verticalOffset: 0.15)
        buildContent()
        previews.onUpdate = { [weak self] in self?.updateHint() }
        weather.onUpdate = { [weak self] in self?.updateWeather() }
        apps.onUpdate = { [weak self] in self?.updateHint() }
    }

    override var initialFirstResponder: NSResponder? { textField }

    /// Opens the bar, optionally with text already typed (cursor at the end).
    func show(prefill: String) {
        pendingPrefill = prefill
        show()
    }

    override func prepareToShow() {
        store.reloadIfNeeded()
        weather.reloadKey()
        apps.refreshIfStale()
        textField.placeholderString = placeholder()
        textField.stringValue = pendingPrefill
        pendingPrefill = ""
        updateHint()
        updateWeather()
    }

    override func didFocus() {
        let end = (textField.stringValue as NSString).length
        textField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    override func didHide() {
        textField.stringValue = ""
        previews.cancel()
        weather.cancel()
        weatherView.isHidden = true
    }

    /// The installed app the input names, when no workflow keyword claims
    /// the input (it would otherwise go to the fallback search).
    private func matchedApp() -> AppEntry? {
        let input = textField.stringValue
        guard store.current.workflowAwaitingArgument(input) == nil,
              CommandParser.parse(input, using: store.current)?.isFallback == true else { return nil }
        return apps.bestMatch(for: input)
    }

    /// Enter: the matching app, else the workflow or fallback URL. ⌘↩
    /// (`searchOnly`) skips the app and runs the fallback search.
    private func execute(searchOnly: Bool = false) {
        // Keyword typed without its argument: keep the bar open and wait.
        if store.current.workflowAwaitingArgument(textField.stringValue) != nil { return }
        if !searchOnly, let app = matchedApp() {
            AppIndex.open(app)
            textField.stringValue = ""
            hide()
            return
        }
        guard let command = CommandParser.parse(textField.stringValue, using: store.current) else {
            hide()
            return
        }
        NSWorkspace.shared.open(command.url)
        textField.stringValue = ""
        hide()
    }

    private func updateHint() {
        // A preview to fetch; anything pending is cancelled when this stays nil.
        var missingPreview: URL?
        // The weather panel replaces the one-line preview when it is shown.
        let showsWeather = weather.query(for: textField.stringValue) != nil
        defer {
            if let missingPreview { previews.fetch(missingPreview) } else { previews.cancel() }
        }

        let app = matchedApp()
        if let app {
            let iconImage = NSWorkspace.shared.icon(forFile: app.url.path)
            iconImage.size = NSSize(width: 24, height: 24)
            icon.image = iconImage
        } else {
            icon.image = searchIcon
        }

        if let app {
            hintLabel.stringValue = "↩ Open \(app.name)  ⌘↩ \(store.current.fallback.title)"
            hintLabel.toolTip = app.url.path
        } else if let workflow = store.current.workflowAwaitingArgument(textField.stringValue) {
            // The keyword is typed but its argument is not: show its help.
            let keyword = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let help = workflow.help ?? "\(workflow.title): type a value after \"\(keyword)\""
            hintLabel.stringValue = help
            hintLabel.toolTip = help
        } else if let command = CommandParser.parse(textField.stringValue, using: store.current) {
            hintLabel.stringValue = "↩ \(command.label)"
            hintLabel.toolTip = nil
            if let preview = command.preview, !showsWeather {
                if let text = previews.cachedText(for: preview) {
                    // e.g. "paris: ☀️ +14°C ↙11km/h  ↩ Weather in paris"
                    hintLabel.stringValue = "\(text)  ↩ \(command.label)"
                    hintLabel.toolTip = text
                } else {
                    missingPreview = preview
                }
            }
        } else if let error = store.loadError {
            hintLabel.stringValue = "⚠ workflows.json: \(error)"
            hintLabel.toolTip = "\(store.fileURL.path)\n\(error)"
        } else {
            hintLabel.stringValue = "esc to close"
            hintLabel.toolTip = nil
        }
    }

    /// Lays out and fills the weather strip above the input (always, while
    /// Config.weatherStrip is on and a WeatherAPI key is set) and the
    /// forecast below it (while the input reads `weather [place]`), resizes
    /// the panel to fit, and asks for whatever is missing.
    private func updateWeather() {
        let homeQuery = Config.weatherStrip ? weather.homeQuery() : nil
        let panelQuery = weather.query(for: textField.stringValue)

        if let homeQuery {
            weatherStrip.show(weather.state(for: homeQuery))
        }
        weatherStrip.isHidden = homeQuery == nil
        let stripHeight = homeQuery == nil ? 0 : WeatherStripView.height
        rowTop?.constant = stripHeight

        if let panelQuery {
            weatherView.show(weather.state(for: panelQuery), for: panelQuery)
        }
        weatherView.isHidden = panelQuery == nil
        setHeight(stripHeight + Self.rowHeight + (panelQuery == nil ? 0 : WeatherView.height))

        // One request at a time: what the input asks for first, then home.
        if let panelQuery, !weather.hasFreshResult(for: panelQuery) {
            weather.request(panelQuery)
        } else if let next = homeQuery ?? panelQuery {
            weather.request(next)
        } else {
            weather.cancel()
        }
    }

    private func placeholder() -> String {
        let set = store.current
        let keywords = set.workflows.compactMap(\.keywords.first).prefix(4)
        guard !keywords.isEmpty else { return set.fallback.title }
        return "\(set.fallback.title), or type \(keywords.joined(separator: ", "))…"
    }

    /// ⌘↩ ignores a matching app and runs the search (or workflow) instead.
    override func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let keyCode = Int(event.keyCode)
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter else { return false }
        execute(searchOnly: true)
        return true
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateHint()
        updateWeather()
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
        Self.styleSearchField(textField, placeholder: placeholder())
        textField.delegate = self

        hintLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        weatherView.isHidden = true
        weatherStrip.isHidden = true

        for view in [weatherStrip, icon, textField, hintLabel, weatherView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        contentView.addLayoutGuide(rowGuide)
        let rowTop = rowGuide.topAnchor.constraint(equalTo: contentView.topAnchor)
        self.rowTop = rowTop

        NSLayoutConstraint.activate([
            weatherStrip.topAnchor.constraint(equalTo: contentView.topAnchor),
            weatherStrip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            weatherStrip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            weatherStrip.heightAnchor.constraint(equalToConstant: WeatherStripView.height),

            rowTop,
            rowGuide.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowGuide.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rowGuide.heightAnchor.constraint(equalToConstant: Self.rowHeight),

            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: rowGuide.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            textField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            textField.centerYAnchor.constraint(equalTo: rowGuide.centerYAnchor),

            hintLabel.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            hintLabel.centerYAnchor.constraint(equalTo: rowGuide.centerYAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),

            weatherView.topAnchor.constraint(equalTo: rowGuide.bottomAnchor),
            weatherView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            weatherView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            weatherView.heightAnchor.constraint(equalToConstant: WeatherView.height),
        ])
    }
}
