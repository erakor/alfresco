// WorkflowCardsView.swift
//
// The commands as cards under the launcher input while it is empty, the
// most run first. Clicking one types its command in the input (`/pr `),
// which hides the cards: Enter, as always, does the rest.

import Cocoa

// MARK: - Model

/// One card: a keyword, with both of its forms when workflows.json has a
/// workflow with `{query}` and one without (`/weather`, `/weather paris`).
struct WorkflowCard: Sendable {
    /// As stored, without the command prefix.
    let keyword: String
    /// The bare form's title when there is one, since Enter runs it once
    /// the card is clicked; else the argument form's.
    let title: String
    let help: String?
    /// The workflow whose URL picks the icon (the same one as `title`).
    let workflow: Workflow
    /// Whether a form takes an argument, so the completion ends with a
    /// space to type it after.
    let takesArgument: Bool
    /// Times either form was run over the kept usage days.
    let runs: Int

    /// What clicking puts in the input: the keyword with its prefix, plus a
    /// space when it can take an argument (`/weather ` still runs the bare
    /// form on Enter, since the input is trimmed).
    var completion: String {
        let typed = CommandInput.typed(keyword)
        return takesArgument ? typed + " " : typed
    }

    /// One card per first keyword, in file order, then sorted by `runs`
    /// (most first; file order breaks ties), at most `limit`. Runs are
    /// counted like UsageStats.recordLaunch counts them: under the first
    /// keyword of the workflow that ran, with " …" for the argument form.
    static func cards(from set: WorkflowSet, usage: UsageTotals, limit: Int) -> [WorkflowCard] {
        var seen = Set<String>()
        var cards: [WorkflowCard] = []
        for keyword in set.workflows.compactMap(\.keywords.first) where seen.insert(keyword).inserted {
            let bare = set.workflow(for: keyword, withArgument: false)
            let withArgument = set.workflow(for: keyword, withArgument: true)
            guard let shown = bare ?? withArgument else { continue }
            let bareRuns = bare?.keywords.first.map { usage.keywords[UsageStats.keywordKey($0, withArgument: false)] ?? 0 } ?? 0
            let argumentRuns = withArgument?.keywords.first.map {
                usage.keywords[UsageStats.keywordKey($0, withArgument: true)] ?? 0
            } ?? 0
            cards.append(WorkflowCard(
                keyword: keyword, title: shown.title, help: shown.help, workflow: shown,
                takesArgument: withArgument != nil, runs: bareRuns + argumentRuns
            ))
        }
        let sorted = cards.enumerated().sorted { lhs, rhs in
            if lhs.element.runs != rhs.element.runs { return lhs.element.runs > rhs.element.runs }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return Array(sorted.prefix(max(0, limit)))
    }
}

// MARK: - Icons

/// The icon of the app that opens a workflow's URL (the default browser for
/// web links), alfresco's own for alfresco:// URLs, else a link symbol.
/// Shared by the suggestion list and the cards, each with its own cache.
@MainActor
enum WorkflowIcon {
    static func image(for workflow: Workflow, cache: inout [String: NSImage]) -> NSImage? {
        let template = workflow.url.replacingOccurrences(of: "{query}", with: "x")
        guard let url = URL(string: template), let scheme = url.scheme?.lowercased() else {
            return NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        }
        if let cached = cache[scheme] { return cached }
        let image: NSImage?
        if scheme == "alfresco" {
            image = NSApp.applicationIconImage
        } else if let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            image = NSWorkspace.shared.icon(forFile: app.path)
        } else {
            image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        }
        cache[scheme] = image
        return image
    }
}

// MARK: - Grid

/// The cards in a grid of `columns`, laid out by hand (the panel's width
/// never changes). LauncherController's InputArea for it sizes it to
/// `preferredHeight` and shows it only while the input is empty.
@MainActor
final class WorkflowCardsView: NSView {
    static let columns = 3
    static let cardHeight: CGFloat = 52
    static let spacing: CGFloat = 10
    /// Space under the last row, above the panel's bottom edge.
    static let bottomPadding: CGFloat = 16

    /// A card was clicked.
    var onPick: ((WorkflowCard) -> Void)?

    private(set) var cards: [WorkflowCard] = []
    private var cardViews: [WorkflowCardView] = []

    override var isFlipped: Bool { true }

    /// The height that shows every card, 0 with none.
    var preferredHeight: CGFloat {
        guard !cards.isEmpty else { return 0 }
        let rows = (cards.count + Self.columns - 1) / Self.columns
        return CGFloat(rows) * Self.cardHeight + CGFloat(rows - 1) * Self.spacing + Self.bottomPadding
    }

    /// Replaces the cards; does nothing when they are the same as shown
    /// (same keywords, titles and order), so typing and clearing the input
    /// doesn't rebuild them. A hover left from before the view was hidden is
    /// cleared, since no exit event came with the panel closing.
    func show(_ cards: [WorkflowCard]) {
        let same = cards.map(\.renderKey) == self.cards.map(\.renderKey)
        if same {
            if isHidden { cardViews.forEach { $0.isHovered = false } }
            return
        }
        self.cards = cards
        cardViews.forEach { $0.removeFromSuperview() }
        var icons: [String: NSImage] = [:]
        cardViews = cards.map { card in
            let view = WorkflowCardView(card: card, icon: WorkflowIcon.image(for: card.workflow, cache: &icons))
            view.onClick = { [weak self] in self?.onPick?(card) }
            addSubview(view)
            return view
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let columns = CGFloat(Self.columns)
        let width = ((bounds.width - (columns - 1) * Self.spacing) / columns).rounded(.down)
        for (index, view) in cardViews.enumerated() {
            let column = CGFloat(index % Self.columns)
            let row = CGFloat(index / Self.columns)
            view.frame = NSRect(
                x: column * (width + Self.spacing), y: row * (Self.cardHeight + Self.spacing),
                width: width, height: Self.cardHeight
            )
        }
    }

    #if SELFTEST
    /// The cards' keywords, in the order shown.
    var keywordsForSelfTest: [String] { cards.map(\.keyword) }

    /// Clicks the card at `index`.
    func clickForSelfTest(_ index: Int) {
        cardViews[index].onClick?()
    }
    #endif
}

private extension WorkflowCard {
    /// What a card shows, to tell whether the grid needs rebuilding.
    var renderKey: String { "\(keyword)\u{1}\(title)\u{1}\(takesArgument)\u{1}\(help ?? "")" }
}

/// A rounded card: the icon on the left, the title and the command (`/pr …`)
/// on the right, highlighted under the mouse. It is never first responder,
/// so a click leaves the input focused.
@MainActor
private final class WorkflowCardView: NSView {
    var onClick: (() -> Void)?
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }
    init(card: WorkflowCard, icon: NSImage?) {
        super.init(frame: .zero)
        toolTip = card.help

        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // Only tints the SF Symbol fallback; app icons keep their colors.
        iconView.contentTintColor = .secondaryLabelColor

        let titleLabel = NSTextField(labelWithString: card.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor

        let typed = CommandInput.typed(card.keyword)
        let commandLabel = NSTextField(labelWithString: card.takesArgument ? "\(typed) …" : typed)
        commandLabel.font = .systemFont(ofSize: 11)
        commandLabel.textColor = .secondaryLabelColor

        for label in [titleLabel, commandLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [iconView, titleLabel, commandLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            commandLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            commandLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            commandLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(card.title)
        setAccessibilityHelp(card.help)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dynamic colors, resolved for the current appearance on each draw.
        let alpha: CGFloat = isPressed ? 0.18 : isHovered ? 0.12 : 0.06
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// Picks the card when the button is released over it, like a button.
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
