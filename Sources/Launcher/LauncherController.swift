// LauncherController.swift
//
// The URL launcher panel: input field, hint line, and Enter handling.

import Cocoa

// MARK: - Launcher window

@MainActor
final class LauncherController: FloatingPanelController, NSTextFieldDelegate {
    private let store: WorkflowStore
    private let textField = NSTextField()
    private let hintLabel = FloatingPanelController.makeHintLabel()
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
        // A preview to fetch; anything pending is cancelled when this stays nil.
        var missingPreview: URL?
        // The weather panel replaces the one-line preview when it is shown.
        let showsWeather = weather.query(for: textField.stringValue) != nil
        defer {
            if let missingPreview { previews.fetch(missingPreview) } else { previews.cancel() }
        }

        if let workflow = store.current.workflowAwaitingArgument(textField.stringValue) {
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
        let icon = Self.makeIcon(symbolName: "magnifyingglass")

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
