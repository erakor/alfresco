// LauncherController.swift
//
// The launcher panel: input field, hint line, keyword suggestions, the
// weather, calendar, pomodoro and usage areas, and Enter handling, which opens a workflow's
// URL or an installed app, or copies a built-in's answer.

import Carbon.HIToolbox
import Cocoa

// MARK: - Area under the input

/// A view that takes the area under the input row in place of the
/// suggestion list: the forecast, the event list, the pomodoro. Each one is an entry in
/// `LauncherController.inputAreas`, which lays them out, hides them with the
/// panel, empties the suggestion list while one claims the input, and sizes
/// the panel for the one shown. Its feature still fills it and sets
/// `view.isHidden`; at most one is shown, since each claims its own keyword.
@MainActor
private final class InputArea {
    let view: NSView
    /// Its height while shown.
    let height: () -> CGFloat
    /// Whether the input as it reads now shows it, and so hides the
    /// suggestion list.
    let claims: () -> Bool
    /// Its own hint line while it claims the input (what Enter does there),
    /// in place of the command's title; nil to keep the launcher's.
    let hint: (() -> String?)?
    /// Kept at `height()` by updateHeight.
    var heightConstraint: NSLayoutConstraint?

    init(
        view: NSView, height: @escaping () -> CGFloat, claims: @escaping () -> Bool,
        hint: (() -> String?)? = nil
    ) {
        self.view = view
        self.height = height
        self.claims = claims
        self.hint = hint
    }
}

// MARK: - Launcher window

@MainActor
final class LauncherController: FloatingPanelController, NSTextFieldDelegate {
    private let store: WorkflowStore
    /// Runs alfresco:// URLs (e.g. alfresco://pomodoro/start,
    /// alfresco://system/lock) inside the app. False means the URL was not understood.
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
    private let calendar = CalendarProvider()
    private let calendarView = CalendarView(frame: .zero)
    /// The next meeting, on the strip's line opposite the weather.
    private let meetingStrip = MeetingStripView(frame: .zero)
    /// The timer `/pomo` drives; nil (no pomodoro view) in self-tests that
    /// don't pass one.
    private let pomodoro: PomodoroTimer?
    private let pomodoroView = PomodoroView(frame: .zero)
    /// What the input runs (CommandParser.parse), worked out once per change
    /// of it (inputDidChange) for the areas that follow a command: the
    /// calendar, the pomodoro and the usage report. Enter parses again.
    private var currentCommand: Command?
    /// The alfresco://pomodoro/... URL the input runs, worked out once per
    /// change of it (inputDidChange), so neither the list nor a tick parses
    /// it again; nil while it is no pomodoro command.
    private var currentPomodoroURL: URL?
    /// The usage report (`/stats`), filled when it appears: the counts
    /// don't change while it is shown, except by what the panel itself does.
    private let statsView = StatsView(frame: .zero)
    /// Whether the input runs alfresco://stats, worked out once per change
    /// of it (inputDidChange).
    private var showsStats = false
    private let suggestionList = SuggestionListView(frame: .zero)
    private let cardsView = WorkflowCardsView(frame: .zero)
    /// The input row (icon, field, hint); moves down when the strip is shown.
    private let rowGuide = NSLayoutGuide()
    private var rowTop: NSLayoutConstraint?
    /// Keeps the meeting clear of the weather while both are shown.
    private var stripGap: NSLayoutConstraint?
    private var suggestionListHeight: NSLayoutConstraint?
    /// What can take the area under the input (see InputArea). A new one
    /// goes here, and its feature shows it and fills it.
    private lazy var inputAreas: [InputArea] = [
        InputArea(
            view: cardsView,
            height: { [unowned self] in self.cardsView.preferredHeight },
            claims: { [unowned self] in self.showsCards(for: self.textField.stringValue) }
        ),
        InputArea(
            view: weatherView,
            height: { WeatherView.height },
            claims: { [unowned self] in self.weather.query(for: self.textField.stringValue) != nil }
        ),
        InputArea(
            view: calendarView,
            height: { [unowned self] in self.calendarView.preferredHeight },
            claims: { [unowned self] in self.currentCalendarQuery != nil }
        ),
        InputArea(
            view: pomodoroView,
            height: { PomodoroView.height },
            claims: { [unowned self] in self.currentPomodoroURL != nil },
            hint: { [unowned self] in self.pomodoroHint() }
        ),
        InputArea(
            view: statsView,
            height: { StatsView.height },
            claims: { [unowned self] in self.showsStats },
            // What Enter does there: the menu bar's Usage… alert.
            hint: { "↩ Last \(UsageStats.summaryDays) days in detail" }
        ),
    ]
    /// Height of the input row, which is the whole panel without the weather.
    private static let rowHeight: CGFloat = 60
    /// Text to start with on the next show(prefill:).
    private var pendingPrefill = ""
    /// Whether Enter opened a URL since the panel was shown (usage stats).
    private var didLaunch = false
    /// How often each app and keyword was used, read when the panel opens,
    /// to rank the list (and so what Enter opens).
    private var usage = UsageTotals()
    /// What a built-in makes of the input, worked out once per change of it
    /// (inputDidChange) and read by the list and the hint. Enter works it
    /// out again, so `now` and `uuid` copy fresh values.
    private var currentBuiltIn: BuiltInAnswer?
    /// The calendar query for the input, worked out once per change of it
    /// (inputDidChange) and by updateCalendar, read by the InputArea test
    /// and the hint. Enter works it out again.
    private var currentCalendarQuery: CalendarQuery?
    /// Whether the calendar list was shown since the panel was (usage stats).
    private var didShowCalendar = false
    /// The input that brought up the calendar permission prompt (which
    /// closes the launcher), to open again on if access is granted; cleared
    /// whenever the launcher opens, so a later session is never replaced.
    private var accessPromptInput: String?
    /// The next show reopens the launcher for the prompt's answer, which is
    /// not an opening to count.
    private var isReopeningForAccess = false
    /// Height of the strip above the input (the weather, the next meeting),
    /// 0 while both are hidden.
    private var stripHeight: CGFloat {
        weatherStrip.isHidden && meetingStrip.isHidden && !holdsStripRow ? 0 : StripButton.stripHeight
    }
    /// Set once the strip's line is up while the panel is shown: it then
    /// keeps its room until the panel closes, so a meeting that starts
    /// never moves the input up under the caret.
    private var holdsStripRow = false
    /// Redraws the calendar and the next meeting while either is shown, so
    /// countdowns and "en cours" follow the clock.
    private var calendarTimer: Timer?
    private static let calendarRefreshInterval: TimeInterval = 30

    init(store: WorkflowStore, pomodoro: PomodoroTimer? = nil, internalURLHandler: @escaping (URL) -> Bool) {
        self.store = store
        self.pomodoro = pomodoro
        self.internalURLHandler = internalURLHandler
        super.init(size: NSSize(width: 680, height: LauncherController.rowHeight), verticalOffset: 0.15)
        buildContent()
        previews.onUpdate = { [weak self] in self?.updateHint() }
        weather.onUpdate = { [weak self] in self?.updateWeather() }
        calendar.onUpdate = { [weak self] in self?.calendarDidUpdate() }
        calendar.onAccessAnswered = { [weak self] in self?.calendarAccessAnswered(granted: $0) }
        apps.onUpdate = { [weak self] in self?.appsDidChange() }
        suggestionList.onPick = { [weak self] in self?.activate($0) }
        suggestionList.onHover = { [weak self] in self?.updateHint() }
        cardsView.onPick = { [weak self] in self?.pick($0) }
        weatherStrip.onClick = { [weak self] in self?.showForecast() }
        meetingStrip.onClick = { [weak self] in self?.showCalendar() }
        pomodoro?.addObserver { [weak self] in self?.pomodoroDidChange() }
    }

    override var initialFirstResponder: NSResponder? { textField }

    /// Opens the bar, optionally with text already typed (cursor at the end).
    func show(prefill: String) {
        pendingPrefill = prefill
        show()
    }

    override func prepareToShow() {
        if !isReopeningForAccess { UsageStats.shared.record(.launcherOpened) }
        isReopeningForAccess = false
        accessPromptInput = nil
        didLaunch = false
        didShowCalendar = false
        usage = UsageStats.shared.totals()
        // Read typed-picks.json while the panel opens, not on the first keystroke.
        _ = TypedAppPicks.shared
        store.reloadIfNeeded()
        weather.reloadKey()
        apps.refreshIfStale()
        textField.placeholderString = placeholder()
        textField.stringValue = pendingPrefill
        pendingPrefill = ""
        inputDidChange()
        // It doesn't depend on the input, so not on every keystroke; the
        // 30 s timer and calendar updates refresh it. After the input's
        // areas, so a prefilled `/cal <text>` starts its own fetch first.
        updateMeetingStrip()
        updateHeight()
    }

    override func didFocus() {
        let end = (textField.stringValue as NSString).length
        textField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    override func didHide() {
        // Closed by the calendar permission prompt, not by the user.
        if !didLaunch, !calendar.isAwaitingAccess {
            let typed = !textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            UsageStats.shared.record(typed ? .launcherClosedTyped : .launcherClosedEmpty)
        }
        textField.stringValue = ""
        currentBuiltIn = nil
        currentCommand = nil
        currentCalendarQuery = nil
        currentPomodoroURL = nil
        showsStats = false
        previews.cancel()
        weather.cancel()
        for area in inputAreas { area.view.isHidden = true }
        weatherStrip.clearHover()
        meetingStrip.clearHover()
        // Worked out again on the next opening; hidden meanwhile so a
        // calendar update doesn't restart the timer.
        meetingStrip.isHidden = true
        holdsStripRow = false
        layoutStrips()
        stopCalendarTimer()
        suggestionList.show([])
        suggestionList.isHidden = true
        suggestionListHeight?.constant = 0
    }

    private func inputDidChange() {
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval(
            "launcher.input", "length=\(self.textField.stringValue.count, privacy: .public)"
        )
        let input = textField.stringValue
        currentBuiltIn = builtInAnswer(for: input)
        currentCommand = CommandParser.parse(input, using: store.current)
        currentCalendarQuery = CalendarQuery.make(input: input, command: currentCommand)
        currentPomodoroURL = pomodoroURL(for: currentCommand)
        showsStats = runsStats(currentCommand)
        updateSuggestions()
        updateHint()
        // Each changes what is under the input: resize once, after all.
        updateCards()
        updateCalendar(resize: false)
        updatePomodoro()
        updateStats()
        updateWeather(resize: false)
        updateHeight()
        signposter.endInterval("launcher.input", signpost, "rows=\(self.suggestionList.items.count, privacy: .public)")
    }

    /// A rescan finished. Nothing to refresh while the panel is hidden
    /// (prepareToShow does it), and refreshing then could start a weather
    /// request nobody asked for. While shown, the list is rebuilt but keeps
    /// its highlighted row if that row is still there, so Enter still does
    /// what the list shows.
    private func appsDidChange() {
        guard isShown else { return }
        let selected = suggestionList.selected
        updateSuggestions()
        if let selected { suggestionList.select(selected) }
        updateHint()
        updateWeather() // resizes the panel to the new list
    }

    /// The installed app the input names, when no workflow keyword or
    /// built-in claims the input (it would otherwise go to the fallback
    /// search).
    private func matchedApp() -> AppEntry? {
        appMatches(for: textField.stringValue, limit: 1).first
    }

    /// The installed apps `input` names, best first, ranked with every
    /// signal (opens over the kept days, the apps picked for this input), so
    /// Enter and the list's first row always agree.
    private func appMatches(for input: String, limit: Int) -> [AppEntry] {
        guard inputCanNameApp(input) else { return [] }
        return apps.matches(
            for: input, limit: limit, openCounts: usage.apps, picks: TypedAppPicks.shared.picks(for: input)
        )
    }

    /// Whether the input would go to the fallback search (or nowhere, when
    /// workflows.json's fallback was refused), which is the only input apps
    /// take (never a workflow keyword or a built-in's input). `input` is the
    /// field's text, so currentBuiltIn is its built-in answer.
    private func inputCanNameApp(_ input: String) -> Bool {
        store.current.workflowAwaitingArgument(input) == nil
            && CommandParser.isUnmatched(input, using: store.current)
            && currentBuiltIn == nil
    }

    /// What a built-in (`= 3*14`, `time tokyo`, `uuid`, `now`) makes of the
    /// input, when no workflow takes it.
    private func builtInAnswer(for input: String) -> BuiltInAnswer? {
        BuiltIns.answer(for: input, workflows: store.current)
    }

    /// Enter on a built-in's input: copies the answer and closes, or beeps
    /// and stays open while there is none (`= 3*`).
    private func copyAnswer(_ answer: BuiltInAnswer) {
        guard let value = answer.value else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            NSSound.beep()
            return
        }
        UsageStats.shared.record(answer.kind.usageCounter)
        didLaunch = true
        textField.stringValue = ""
        hide()
    }

    private func open(_ app: AppEntry) {
        // Counted when asked: opening an app reports failure later.
        AppIndex.open(app)
        UsageStats.shared.recordAppOpened(bundleID: app.bundleID)
        // What was typed to find it, so typing that again puts it first.
        TypedAppPicks.shared.record(input: textField.stringValue, bundleID: app.bundleID)
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

    /// Enter: a built-in's answer, else the matching app, else the workflow
    /// (`/pr 12`) or fallback URL. ⌘↩ (`searchOnly`) skips built-ins and the
    /// app and runs the fallback search; for command input it searches for
    /// what is typed, `/` included.
    private func execute(searchOnly: Bool = false) {
        // Keyword typed without its argument: keep the bar open and wait.
        if store.current.workflowAwaitingArgument(textField.stringValue) != nil {
            UsageStats.shared.record(.launcherEnterNeedsArgument)
            return
        }
        if !searchOnly, let answer = builtInAnswer(for: textField.stringValue) {
            copyAnswer(answer)
            return
        }
        if !searchOnly, let app = matchedApp() {
            open(app)
            return
        }
        let input = textField.stringValue
        // ⌘↩ on `/r/swift`: searched for as typed, which Enter never does.
        let parsed = searchOnly && CommandInput.isCommand(input)
            ? CommandParser.fallbackCommand(input, using: store.current)
            : enterCommand(for: input, query: calendarQuery(for: input))
        guard let command = parsed else {
            if CommandInput.isCommand(input) {
                // `/`, `/help` with no row chosen, or a command no workflow
                // has: the hint says which. Never searched for, but a
                // mistyped keyword is counted like a fallback word.
                if !store.current.listsAllCommands(input), let body = CommandInput.body(of: input) {
                    UsageStats.shared.recordUnknownCommand(body, keywords: store.current.keywords)
                }
                NSSound.beep()
                return
            }
            if store.current.fallback == nil, CommandParser.isUnmatched(textField.stringValue, using: store.current) {
                // workflows.json's fallback was refused: nowhere to send this,
                // and the hint says why. Never another search instead.
                NSSound.beep()
                return
            }
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
            UsageStats.shared.recordLaunch(
                command.source, input: textField.stringValue,
                keywords: store.current.keywords
            )
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
    /// start with what is typed after the command prefix (every one for `/`
    /// or `/help`), then the other matching apps, up to nine rows unless
    /// there are more keywords. Empty while an InputArea claims the input
    /// (it takes that space).
    private func updateSuggestions() {
        let input = textField.stringValue
        var items: [LauncherItem] = []
        var highlightFirst = false
        if !inputAreas.contains(where: { $0.claims() }) {
            let workflows = sortedByUse(store.current.suggestions(for: input), input: input)
            let appLimit = max(1, SuggestionListView.maxVisibleRows - workflows.count)
            let matchedApps = appMatches(for: input, limit: appLimit)
            if let best = matchedApps.first {
                items.append(.app(best))
                highlightFirst = true
            }
            items += workflows.map(LauncherItem.workflow)
            items += matchedApps.dropFirst().map(LauncherItem.app)
        }
        suggestionList.show(items, highlightFirst: highlightFirst)
        suggestionList.isHidden = items.isEmpty
        suggestionListHeight?.constant = suggestionList.preferredHeight
    }

    /// Whether the command cards take the area under the input: only while
    /// it is empty (spaces count as empty), and only when they are on and
    /// workflows.json has a command.
    private func showsCards(for input: String) -> Bool {
        Config.workflowCardLimit.map { $0 > 0 } == true
            && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.current.workflows.isEmpty
    }

    /// Fills the cards while the input is empty, the most run first (from
    /// the usage read when the panel opened). updateHeight sizes the panel.
    private func updateCards() {
        let shown = showsCards(for: textField.stringValue)
        if shown, let limit = Config.workflowCardLimit {
            cardsView.show(WorkflowCard.cards(from: store.current, usage: usage, limit: limit))
        }
        cardsView.isHidden = !shown
    }

    /// A card was clicked: its command goes in the input (`/pr `), which
    /// hides the cards, and Enter or the argument comes next.
    private func pick(_ card: WorkflowCard) {
        UsageStats.shared.record(.launcherCardPicked)
        complete(with: card.completion)
    }

    /// The weather strip was clicked: `/weather` goes in the input, which
    /// opens the forecast for the same place as the strip. Enter then runs
    /// the `weather` workflow, as when it is typed.
    private func showForecast() {
        UsageStats.shared.record(.launcherWeatherStripClicked)
        complete(with: CommandInput.typed(Config.weatherKeyword))
    }

    /// The next meeting was clicked: `/cal` goes in the input, which opens
    /// the event list. Beeps when no `cal` workflow takes it (the list
    /// would not show).
    private func showCalendar() {
        let typed = CommandInput.typed(Config.calendarKeyword)
        guard calendarQuery(for: typed) != nil else {
            NSSound.beep()
            return
        }
        UsageStats.shared.record(.launcherMeetingStripClicked)
        complete(with: typed)
    }

    /// Keyword suggestions with the one typed in full first (as before),
    /// then the most run ones; file order breaks ties.
    private func sortedByUse(_ suggestions: [Suggestion], input: String) -> [Suggestion] {
        let typed = CommandInput.body(of: input)?.lowercased()
        func runs(_ suggestion: Suggestion) -> Int {
            // Counted under the workflow's first keyword (Command.source).
            guard let keyword = suggestion.workflow.keywords.first else { return 0 }
            return usage.keywords[UsageStats.keywordKey(keyword, withArgument: suggestion.workflow.takesArgument)] ?? 0
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

        // A highlighted row takes Enter; without one, a built-in or the
        // matching app does (never both: apps don't take a built-in's input).
        let app: AppEntry?
        switch suggestionList.selected {
        case .app(let selectedApp)?: app = selectedApp
        case .workflow?: app = nil
        case nil: app = matchedApp()
        }
        let builtIn = suggestionList.selected == nil ? currentBuiltIn : nil
        if let app {
            let iconImage = NSWorkspace.shared.icon(forFile: app.url.path)
            iconImage.size = NSSize(width: 24, height: 24)
            icon.image = iconImage
        } else if let builtIn {
            icon.image = NSImage(systemSymbolName: builtIn.kind.symbolName, accessibilityDescription: nil) ?? searchIcon
        } else {
            icon.image = searchIcon
        }

        if case .workflow(let suggestion)? = suggestionList.selected {
            // A highlighted workflow row: Enter takes it.
            let title = suggestion.workflow.title
            hintLabel.stringValue = suggestion.workflow.takesArgument ? "↩ \(title)…" : "↩ \(title)"
            hintLabel.toolTip = nil
        } else if let builtIn {
            hintLabel.stringValue = builtIn.hint
            hintLabel.toolTip = builtIn.detail
        } else if let app {
            hintLabel.stringValue = "↩ Open \(app.name)" + (store.current.fallback.map { "  ⌘↩ \($0.title)" } ?? "")
            hintLabel.toolTip = app.url.path
        } else if let workflow = store.current.workflowAwaitingArgument(textField.stringValue) {
            // The keyword is typed but its argument is not: show its help.
            let keyword = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let help = workflow.help ?? "\(workflow.title): type a value after \"\(keyword)\""
            hintLabel.stringValue = help
            hintLabel.toolTip = help
        } else if let text = areaHint() {
            // The area under the input says what Enter does (`/pomo`).
            hintLabel.stringValue = text
            hintLabel.toolTip = nil
        } else if let command = enterCommand(for: textField.stringValue, query: currentCalendarQuery) {
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
        } else if store.current.listsAllCommands(textField.stringValue) {
            // Command hints come before a workflows.json error, which then
            // stays in the tooltip: a refused entry leaves the rest usable.
            hintLabel.stringValue = suggestionList.items.isEmpty ? "No commands in workflows.json" : "↓ to pick a command, ⇥ to complete"
            hintLabel.toolTip = loadErrorTooltip()
        } else if CommandInput.isCommand(textField.stringValue) {
            let typed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let list = CommandInput.typed(Config.commandListKeyword)
            // ⌘↩ still searches for it (a pasted `/r/swift` or a path).
            let search = store.current.fallback.map { "  ⌘↩ \($0.title)" } ?? ""
            hintLabel.stringValue = (suggestionList.items.isEmpty ? "No command \(typed), \(list) lists them" : "⇥ to complete") + search
            hintLabel.toolTip = loadErrorTooltip()
        } else if let error = store.loadError {
            hintLabel.stringValue = "⚠ workflows.json: \(error)"
            hintLabel.toolTip = loadErrorTooltip()
        } else {
            hintLabel.stringValue = "esc to close"
            hintLabel.toolTip = nil
        }
    }

    /// The hint of the InputArea that claims the input, when it has its own.
    private func areaHint() -> String? {
        for area in inputAreas where area.hint != nil && area.claims() {
            return area.hint?()
        }
        return nil
    }

    /// The workflows.json error with the file's path, or nil when it loaded.
    private func loadErrorTooltip() -> String? {
        store.loadError.map { "⚠ \(store.fileURL.path)\n\($0)" }
    }

    /// Lays out and fills the weather strip above the input (always, while
    /// Config.weatherStrip is on and a WeatherAPI key is set) and the
    /// forecast below it (while the input reads `/weather [place]`), resizes
    /// the panel to fit (the suggestion list included), and asks for
    /// whatever is missing.
    private func updateWeather(resize: Bool = true) {
        let homeQuery = Config.weatherStrip ? weather.homeQuery() : nil
        let panelQuery = weather.query(for: textField.stringValue)

        if let homeQuery {
            weatherStrip.show(weather.state(for: homeQuery))
        }
        weatherStrip.isHidden = homeQuery == nil
        layoutStrips()

        if let panelQuery {
            weatherView.show(weather.state(for: panelQuery), for: panelQuery)
        }
        weatherView.isHidden = panelQuery == nil
        if resize { updateHeight() }

        // One request at a time: what the input asks for first, then home.
        if let panelQuery, !weather.hasFreshResult(for: panelQuery) {
            weather.request(panelQuery)
        } else if let next = homeQuery ?? panelQuery {
            weather.request(next)
        } else {
            weather.cancel()
        }
    }

    /// The calendar query for `input`: only while it runs a workflow whose
    /// first keyword is Config.calendarKeyword (the `cal` workflows in
    /// workflows.json), so Enter does what the list is about. Without one,
    /// `/cal` is an unknown command and beeps. `/cal demain` is a `.day`
    /// (CalendarQuery.make), which needs the `{query}` form too.
    private func calendarQuery(for input: String) -> CalendarQuery? {
        CalendarQuery.make(input: input, command: CommandParser.parse(input, using: store.current))
    }

    /// What Enter runs for `input`, which reads `query`: CommandParser.parse,
    /// except that a day in `/cal` (`/cal demain`) runs the bare `/cal`
    /// workflow (CalendarQuery.enterCommand).
    private func enterCommand(for input: String, query: CalendarQuery?) -> Command? {
        CalendarQuery.enterCommand(CommandParser.parse(input, using: store.current), query: query, using: store.current)
    }

    /// Fills the event list under the input while it reads `/cal [text]`,
    /// then resizes the panel unless the caller does (`resize: false`).
    private func updateCalendar(resize: Bool = true) {
        let input = textField.stringValue
        let query = currentCalendarQuery
        if let query {
            if !didShowCalendar {
                didShowCalendar = true
                UsageStats.shared.record(.calendarShown)
            }
            let state = calendar.state(for: query)
            if calendar.isAwaitingAccess { accessPromptInput = input }
            calendarView.show(state, for: query)
        }
        calendarView.isHidden = query == nil
        updateCalendarTimer()
        if resize { updateHeight() }
    }

    /// Shows the next meeting above the input, left of the weather, while
    /// Config.calendarStrip is on, calendar access was already granted (the
    /// strip never asks), and a timed event starts within
    /// Config.calendarDays. Reads the same events as `/cal`, fetching them
    /// when missing or stale; the result comes back through
    /// calendarDidUpdate. Until the first events arrive it says so, like
    /// the weather, so the line doesn't appear under the user's typing.
    /// The caller sizes the panel.
    private func updateMeetingStrip() {
        let now = Date()
        var next: CalendarEvent?
        var isLoading = false
        if Config.calendarStrip, calendar.canReadWithoutAsking {
            switch calendar.state(for: .upcoming) {
            case .loaded(let events, _): next = NextMeeting.find(in: events, now: now)
            case .loading: isLoading = true
            case .message: break
            }
        }
        if let next {
            meetingStrip.show(next, now: now)
        } else if isLoading {
            meetingStrip.showLoading()
        }
        if isShown, stripHeight > 0 { holdsStripRow = true }
        meetingStrip.isHidden = next == nil && !isLoading
        layoutStrips()
        updateCalendarTimer()
    }

    /// New events, or the calendars changed: the list and the next meeting
    /// follow (the meeting only while the panel is shown, so a change in a
    /// calendar never starts a fetch for a closed launcher).
    private func calendarDidUpdate() {
        updateCalendar(resize: false)
        if isShown { updateMeetingStrip() }
        updateHeight()
    }

    /// Room for the strip above the input while the weather or the next
    /// meeting is shown, and the gap between them when both are.
    private func layoutStrips() {
        rowTop?.constant = stripHeight
        stripGap?.isActive = !weatherStrip.isHidden && !meetingStrip.isHidden
    }

    /// Clicking the permission prompt closes the launcher. If access was
    /// granted and the launcher hasn't been opened since, open it again on
    /// what was typed; otherwise just redraw (the next `/cal` shows the
    /// refusal).
    private func calendarAccessAnswered(granted: Bool) {
        let input = accessPromptInput
        accessPromptInput = nil
        if isShown {
            calendarDidUpdate()
        } else if granted, let input {
            // A fade-out still running is cancelled by show() (see
            // FloatingPanelController.finishHide).
            isReopeningForAccess = true
            show(prefill: input)
        }
    }

    /// The 30 s redraw runs while the event list or the next meeting is
    /// shown.
    private func updateCalendarTimer() {
        if calendarView.isHidden && meetingStrip.isHidden {
            stopCalendarTimer()
        } else {
            startCalendarTimer()
        }
    }

    private func startCalendarTimer() {
        guard calendarTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.calendarRefreshInterval, target: self,
            selector: #selector(calendarTimerFired), userInfo: nil, repeats: true
        )
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        calendarTimer = timer
    }

    private func stopCalendarTimer() {
        calendarTimer?.invalidate()
        calendarTimer = nil
    }

    @objc private func calendarTimerFired() {
        guard currentCalendarQuery != nil else {
            // Only the next meeting is shown: the input needs no parsing.
            updateMeetingStrip()
            updateHeight()
            return
        }
        // `/cal demain` names another day after midnight.
        currentCalendarQuery = CalendarQuery.make(input: textField.stringValue, command: currentCommand)
        calendarDidUpdate()
    }

    /// The alfresco://pomodoro/... URL `command` opens (`/pomo`, `/pomo 50`,
    /// or any workflow pointing there), while there is a timer to show.
    private func pomodoroURL(for command: Command?) -> URL? {
        guard pomodoro != nil, let url = command?.url,
              InternalURL.feature(of: url) == PomodoroCommand.feature
        else { return nil }
        return url
    }

    /// The pomodoro area's hint: what Enter would do to the timer now
    /// (PomodoroCommand.preview); nil while the input is no pomodoro command.
    private func pomodoroHint() -> String? {
        guard let pomodoro, let url = currentPomodoroURL else { return nil }
        // nil for an action it doesn't know (`/pomo 500`), which the preview explains.
        return pomodoro.preview(of: PomodoroCommand(url: url)).hint
    }

    /// Fills the pomodoro view while the input is a pomodoro command. Its
    /// height is fixed, so inputDidChange's updateHeight covers it.
    private func updatePomodoro() {
        if let pomodoro, let url = currentPomodoroURL {
            let startMinutes = PomodoroCommand(url: url)?.startMinutes ?? PomodoroPhase.focus.minutes
            pomodoroView.show(pomodoro, startMinutes: startMinutes)
        }
        pomodoroView.isHidden = currentPomodoroURL == nil
    }

    /// Every timer change and tick, while the view is shown: it follows, and
    /// so does the hint, which is the pomodoro's then (Enter may now do
    /// something else, e.g. once a break starts by itself).
    private func pomodoroDidChange() {
        guard isShown, !pomodoroView.isHidden else { return }
        updatePomodoro()
        if let hint = pomodoroHint(), hintLabel.stringValue != hint {
            hintLabel.stringValue = hint
        }
    }

    /// Whether `command` opens alfresco://stats (the `/stats` workflow),
    /// while the usage stats are on.
    private func runsStats(_ command: Command?) -> Bool {
        Config.usageTracking && command.map { StatsCommand.isSummary($0.url) } == true
    }

    /// Fills the usage report as it appears (not on every keystroke after:
    /// nothing typed changes the counts). Its height is fixed, so
    /// inputDidChange's updateHeight covers it.
    private func updateStats() {
        if showsStats, statsView.isHidden {
            let signposter = Signposts.signposter
            let signpost = signposter.beginInterval("stats.report")
            let report = UsageReport.make(from: UsageStats.shared, workflows: store.current)
            statsView.show(report, workflows: store.current)
            signposter.endInterval(
                "stats.report", signpost,
                "commands=\(report.topCommands.count, privacy: .public) apps=\(report.topApps.count, privacy: .public)"
            )
        }
        statsView.isHidden = !showsStats
    }

    /// Sizes the panel for the strip, the input row, and the InputArea
    /// shown below it, else the suggestion list.
    private func updateHeight() {
        let below: CGFloat
        if let shown = inputAreas.first(where: { !$0.view.isHidden }) {
            below = shown.height()
            shown.heightConstraint?.constant = below
        } else {
            below = suggestionList.preferredHeight
        }
        setHeight(stripHeight + Self.rowHeight + below)
    }

    private func placeholder() -> String {
        let set = store.current
        if let prefix = Config.commandPrefix, !set.workflows.isEmpty {
            let commands = "\(prefix) for commands"
            return set.fallback.map { "\($0.title), or \(commands)" } ?? "Type \(commands)"
        }
        let keywords = set.workflows.compactMap(\.keywords.first).prefix(4).map(CommandInput.typed)
        let list = keywords.joined(separator: ", ")
        guard let search = set.fallback?.title else { return keywords.isEmpty ? "" : "Type \(list)…" }
        return keywords.isEmpty ? search : "\(search), or type \(list)…"
    }

    /// ⌘↩ ignores a matching app and runs the search instead (for `/…`
    /// input too, so `/r/swift` can still be searched for).
    /// ⌘1 to ⌘9 take the Nth row of the list.
    override func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let keyCode = Int(event.keyCode)
        guard event.shortcutModifiers == .command else { return false }
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

    #if SELFTEST
    /// Puts `text` in the input as typing it would.
    func typeForSelfTest(_ text: String) {
        textField.stringValue = text
        inputDidChange()
    }

    /// The command cards' keywords while they are shown, else nil.
    var cardKeywordsForSelfTest: [String]? { cardsView.isHidden ? nil : cardsView.keywordsForSelfTest }

    /// Clicks the card at `index`.
    func clickCardForSelfTest(_ index: Int) { cardsView.clickForSelfTest(index) }

    /// Clicks the weather strip (hidden in the test build, which has no
    /// WeatherAPI key, but its click still goes through).
    func clickWeatherStripForSelfTest() { weatherStrip.clickForSelfTest() }

    /// Clicks the next meeting (hidden in the test build, which has no
    /// calendar access, but its click still goes through).
    func clickMeetingStripForSelfTest() { meetingStrip.clickForSelfTest() }

    /// Works out the next meeting as opening the panel does.
    func updateMeetingStripForSelfTest() { updateMeetingStrip() }

    /// What the next meeting reads while it is shown, else nil.
    var meetingStripForSelfTest: String? { meetingStrip.isHidden ? nil : meetingStrip.textForSelfTest }

    /// What the input reads.
    var inputForSelfTest: String { textField.stringValue }

    /// The hint line, right of the input.
    var hintForSelfTest: String { hintLabel.stringValue }

    /// The usage report while it is shown, else nil.
    var statsForSelfTest: UsageReport? { statsView.isHidden ? nil : statsView.reportForSelfTest }

    /// What the pomodoro view shows while it is shown, else nil.
    var pomodoroForSelfTest: PomodoroViewContent? {
        pomodoroView.isHidden ? nil : pomodoroView.contentForSelfTest
    }

    /// The installed apps found so far (0 until the first scan finishes).
    var appCountForSelfTest: Int { apps.apps.count }
    #endif

    // MARK: Setup

    private func buildContent() {
        Self.styleSearchField(textField, placeholder: placeholder())
        textField.delegate = self

        hintLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        weatherStrip.isHidden = true
        meetingStrip.isHidden = true
        suggestionList.isHidden = true

        for view in [meetingStrip, weatherStrip, icon, textField, hintLabel, suggestionList] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        contentView.addLayoutGuide(rowGuide)
        let rowTop = rowGuide.topAnchor.constraint(equalTo: contentView.topAnchor)
        self.rowTop = rowTop
        let suggestionListHeight = suggestionList.heightAnchor.constraint(equalToConstant: 0)
        self.suggestionListHeight = suggestionListHeight
        // Both strips hug their content; this one only applies while both
        // are shown (layoutStrips), and the meeting's title gives way first.
        stripGap = meetingStrip.trailingAnchor.constraint(lessThanOrEqualTo: weatherStrip.leadingAnchor, constant: -12)

        // The strips' content lines up with the input row's edges (20 pt
        // in); their click highlight reaches a little past.
        let stripInset = 20 - StripButton.inset
        NSLayoutConstraint.activate([
            meetingStrip.topAnchor.constraint(equalTo: contentView.topAnchor),
            meetingStrip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: stripInset),
            meetingStrip.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -stripInset),
            meetingStrip.heightAnchor.constraint(equalToConstant: StripButton.stripHeight),

            weatherStrip.topAnchor.constraint(equalTo: contentView.topAnchor),
            weatherStrip.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: stripInset),
            weatherStrip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -stripInset),
            weatherStrip.heightAnchor.constraint(equalToConstant: StripButton.stripHeight),

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

            suggestionList.topAnchor.constraint(equalTo: rowGuide.bottomAnchor),
            suggestionList.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            suggestionList.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            suggestionListHeight,
        ])

        // Each area sits under the input row, inset like it, hidden until
        // its feature shows it.
        for area in inputAreas {
            let view = area.view
            view.isHidden = true
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            let height = view.heightAnchor.constraint(equalToConstant: area.height())
            area.heightConstraint = height
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: rowGuide.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
                height,
            ])
        }
    }
}
