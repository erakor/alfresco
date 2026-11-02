// LauncherController.swift
//
// The launcher panel: input field, hint line, keyword suggestions, and
// Enter handling, which opens a workflow's URL or an installed app.

import Carbon.HIToolbox
import Cocoa

// MARK: - Launcher window

@MainActor
final class LauncherController: FloatingPanelController, NSTextFieldDelegate {
    private let store: WorkflowStore
    /// Runs alfresco:// URLs (e.g. alfresco://pomodoro/start) inside the
    /// app. False means the URL was not understood.
    private let internalURLHandler: (URL) -> Bool
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
    private let suggestionList = SuggestionListView(frame: .zero)
    /// The input row (icon, field, hint); moves down when the strip is shown.
    private let rowGuide = NSLayoutGuide()
    private var rowTop: NSLayoutConstraint?
    private var suggestionListHeight: NSLayoutConstraint?
    /// Height of the input row, which is the whole panel without the weather.
    private static let rowHeight: CGFloat = 60
    /// Text to start with on the next show(prefill:).
    private var pendingPrefill = ""
    /// Whether Enter opened a URL since the panel was shown (usage stats).
    private var didLaunch = false
    /// How often each app and keyword was used, read when the panel opens,
    /// to rank the list (and so what Enter opens).
    private var usage = UsageTotals()

    init(store: WorkflowStore, internalURLHandler: @escaping (URL) -> Bool) {
        self.store = store
        self.internalURLHandler = internalURLHandler
        super.init(size: NSSize(width: 680, height: LauncherController.rowHeight), verticalOffset: 0.15)
        buildContent()
        previews.onUpdate = { [weak self] in self?.updateHint() }
        weather.onUpdate = { [weak self] in self?.updateWeather() }
        apps.onUpdate = { [weak self] in self?.inputDidChange() }
        suggestionList.onPick = { [weak self] in self?.activate($0) }
    }

    override var initialFirstResponder: NSResponder? { textField }

    /// Opens the bar, optionally with text already typed (cursor at the end).
    func show(prefill: String) {
        pendingPrefill = prefill
        show()
    }

    override func prepareToShow() {
        UsageStats.shared.record(.launcherOpened)
        didLaunch = false
        usage = UsageStats.shared.totals()
        store.reloadIfNeeded()
        weather.reloadKey()
        apps.refreshIfStale()
        textField.placeholderString = placeholder()
        textField.stringValue = pendingPrefill
        pendingPrefill = ""
        inputDidChange()
    }

    override func didFocus() {
        let end = (textField.stringValue as NSString).length
        textField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    override func didHide() {
        if !didLaunch {
            let typed = !textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            UsageStats.shared.record(typed ? .launcherClosedTyped : .launcherClosedEmpty)
        }
        textField.stringValue = ""
        previews.cancel()
        weather.cancel()
        weatherView.isHidden = true
        suggestionList.show([])
        suggestionList.isHidden = true
        suggestionListHeight?.constant = 0
    }

    private func inputDidChange() {
        updateSuggestions()
        updateHint()
        updateWeather()
    }

    /// The installed app the input names, when no workflow keyword claims
    /// the input (it would otherwise go to the fallback search).
    private func matchedApp() -> AppEntry? {
        let input = textField.stringValue
        return inputCanNameApp(input) ? apps.bestMatch(for: input, openCounts: usage.apps) : nil
    }

    /// Whether the input would go to the fallback search, which is the only
    /// input apps take (never a workflow keyword).
    private func inputCanNameApp(_ input: String) -> Bool {
        store.current.workflowAwaitingArgument(input) == nil
            && CommandParser.parse(input, using: store.current)?.isFallback == true
    }

    private func open(_ app: AppEntry) {
        // Counted when asked: opening an app reports failure later.
        AppIndex.open(app)
        UsageStats.shared.recordAppOpened(bundleID: app.bundleID)
        didLaunch = true
        textField.stringValue = ""
        hide()
    }

    /// A list row taken with Enter, ⌘1 to ⌘9 or a click: an app opens; a
    /// workflow is completed, then run if it needs no argument.
    private func activate(_ item: LauncherItem) {
        switch item {
        case .app(let app):
            open(app)
        case .workflow(let suggestion):
            complete(with: suggestion.completion)
            if !suggestion.workflow.takesArgument { execute() }
        }
    }

    /// Enter: the matching app, else the workflow or fallback URL. ⌘↩
    /// (`searchOnly`) skips the app and runs the fallback search.
    private func execute(searchOnly: Bool = false) {
        // Keyword typed without its argument: keep the bar open and wait.
        if store.current.workflowAwaitingArgument(textField.stringValue) != nil {
            UsageStats.shared.record(.launcherEnterNeedsArgument)
            return
        }
        if !searchOnly, let app = matchedApp() {
            open(app)
            return
        }
        guard let command = CommandParser.parse(textField.stringValue, using: store.current) else {
            hide()
            return
        }
        let opened: Bool
        if command.url.scheme?.lowercased() == "alfresco" {
            // Handled by the app itself; an unknown one keeps the bar open.
            guard internalURLHandler(command.url) else {
                NSSound.beep()
                return
            }
            opened = true
        } else {
            // false when macOS can't open it.
            opened = NSWorkspace.shared.open(command.url)
        }
        // On failure the text stays, so didHide counts a close with text
        // typed instead of a launch.
        if opened {
            UsageStats.shared.recordLaunch(command.source, input: textField.stringValue)
            didLaunch = true
            textField.stringValue = ""
        }
        hide()
    }

    /// Puts a row's completion in the field (a workflow's keyword plus a
    /// space when it needs an argument, or an app's name), cursor at the
    /// end. Goes through the field editor when there is one, so ⌘Z brings
    /// back what was typed.
    private func complete(with completion: String) {
        if let editor = textField.currentEditor() as? NSTextView {
            editor.breakUndoCoalescing()
            editor.insertText(completion, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            editor.breakUndoCoalescing()
        } else {
            textField.stringValue = completion
        }
        inputDidChange()
    }

    /// Fills the list under the input: the best matching app first (it is
    /// what Enter opens, so it starts highlighted), then the keywords that
    /// start with what is typed, then the other matching apps, up to nine
    /// rows unless there are more keywords. The forecast takes that space
    /// while it is shown.
    private func updateSuggestions() {
        let input = textField.stringValue
        var items: [LauncherItem] = []
        var highlightFirst = false
        if weather.query(for: input) == nil {
            let workflows = sortedByUse(store.current.suggestions(for: input), input: input)
            let appLimit = max(1, SuggestionListView.maxVisibleRows - workflows.count)
            let appMatches = inputCanNameApp(input)
                ? apps.matches(for: input, limit: appLimit, openCounts: usage.apps) : []
            if let best = appMatches.first {
                items.append(.app(best))
                highlightFirst = true
            }
            items += workflows.map(LauncherItem.workflow)
            items += appMatches.dropFirst().map(LauncherItem.app)
        }
        suggestionList.show(items, highlightFirst: highlightFirst)
        suggestionList.isHidden = items.isEmpty
        suggestionListHeight?.constant = suggestionList.preferredHeight
    }

    /// Keyword suggestions with the one typed in full first (as before),
    /// then the most run ones; file order breaks ties.
    private func sortedByUse(_ suggestions: [Suggestion], input: String) -> [Suggestion] {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func runs(_ suggestion: Suggestion) -> Int {
            // Counted under the workflow's first keyword (Command.source).
            guard let keyword = suggestion.workflow.keywords.first else { return 0 }
            return usage.keywords[suggestion.workflow.takesArgument ? "\(keyword) …" : keyword] ?? 0
        }
        return suggestions.enumerated().sorted { lhs, rhs in
            let lhsExact = lhs.element.keyword == typed
            let rhsExact = rhs.element.keyword == typed
            if lhsExact != rhsExact { return lhsExact }
            let lhsRuns = runs(lhs.element)
            let rhsRuns = runs(rhs.element)
            if lhsRuns != rhsRuns { return lhsRuns > rhsRuns }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func updateHint() {
        // A preview to fetch; anything pending is cancelled when this stays nil.
        var missingPreview: URL?
        // The weather panel replaces the one-line preview when it is shown.
        let showsWeather = weather.query(for: textField.stringValue) != nil
        defer {
            if let missingPreview { previews.fetch(missingPreview) } else { previews.cancel() }
        }

        // A highlighted row takes Enter; without one, the matching app does.
        let app: AppEntry?
        switch suggestionList.selected {
        case .app(let selectedApp)?: app = selectedApp
        case .workflow?: app = nil
        case nil: app = matchedApp()
        }
        if let app {
            let iconImage = NSWorkspace.shared.icon(forFile: app.url.path)
            iconImage.size = NSSize(width: 24, height: 24)
            icon.image = iconImage
        } else {
            icon.image = searchIcon
        }

        if case .workflow(let suggestion)? = suggestionList.selected {
            // A highlighted workflow row: Enter takes it.
            let title = suggestion.workflow.title
            hintLabel.stringValue = suggestion.workflow.takesArgument ? "↩ \(title)…" : "↩ \(title)"
            hintLabel.toolTip = nil
        } else if let app {
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
    /// the panel to fit (the suggestion list included), and asks for
    /// whatever is missing.
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
        let below = panelQuery == nil ? suggestionList.preferredHeight : WeatherView.height
        setHeight(stripHeight + Self.rowHeight + below)

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
    /// ⌘1 to ⌘9 take the Nth row of the list.
    override func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let keyCode = Int(event.keyCode)
        // Only the shortcut modifiers: Caps Lock and keypad Enter's
        // .numericPad flag must not get in the way.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command else { return false }
        if keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            execute(searchOnly: true)
            return true
        }
        guard let number = DigitShortcuts.keyCodes[keyCode], !suggestionList.isHidden else { return false }
        if let item = suggestionList.item(number: number) {
            activate(item)
        } else {
            NSSound.beep()
        }
        return true
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        inputDidChange()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let hasSuggestions = !suggestionList.items.isEmpty
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            // Never moves focus out of the field; completes when it can.
            if let target = suggestionList.tabTarget { complete(with: target.completion) }
            return true
        case #selector(NSResponder.moveDown(_:)) where hasSuggestions:
            suggestionList.moveSelection(by: 1)
            updateHint()
            return true
        case #selector(NSResponder.moveUp(_:)) where hasSuggestions:
            suggestionList.moveSelection(by: -1)
            updateHint()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let item = suggestionList.selected {
                activate(item)
            } else {
                execute()
            }
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
        suggestionList.isHidden = true

        for view in [weatherStrip, icon, textField, hintLabel, weatherView, suggestionList] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        contentView.addLayoutGuide(rowGuide)
        let rowTop = rowGuide.topAnchor.constraint(equalTo: contentView.topAnchor)
        self.rowTop = rowTop
        let suggestionListHeight = suggestionList.heightAnchor.constraint(equalToConstant: 0)
        self.suggestionListHeight = suggestionListHeight

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

            suggestionList.topAnchor.constraint(equalTo: rowGuide.bottomAnchor),
            suggestionList.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            suggestionList.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            suggestionListHeight,
        ])
    }
}
