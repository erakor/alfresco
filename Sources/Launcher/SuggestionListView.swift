// SuggestionListView.swift
//
// The list under the launcher input that shows workflows whose keyword
// starts with what is typed. The input keeps focus: LauncherController
// routes Tab, ↑ and ↓ here.

import Cocoa

@MainActor
final class SuggestionListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 40
    /// More rows than this scroll.
    static let maxVisibleRows = 5
    /// Space above and below the rows.
    static let padding: CGFloat = 6
    /// Where the keyword starts, lined up with the text in the input above.
    static let textInset: CGFloat = 56

    /// A row was clicked.
    var onPick: ((Suggestion) -> Void)?

    private(set) var suggestions: [Suggestion] = []
    /// The row chosen with ↑ ↓; nil until then, so Enter keeps running what
    /// is typed.
    private var selectedIndex: Int?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /// The row chosen with ↑ ↓, if any.
    var selected: Suggestion? { selectedIndex.map { suggestions[$0] } }

    /// What Tab completes: the chosen row, else the first.
    var tabTarget: Suggestion? { selected ?? suggestions.first }

    /// The height that shows the rows (up to maxVisibleRows), 0 when empty.
    var preferredHeight: CGFloat {
        guard !suggestions.isEmpty else { return 0 }
        return CGFloat(min(suggestions.count, Self.maxVisibleRows)) * Self.rowHeight + 2 * Self.padding
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Replaces the rows and clears the choice.
    func show(_ suggestions: [Suggestion]) {
        self.suggestions = suggestions
        selectedIndex = nil
        tableView.reloadData()
        syncSelection()
    }

    /// ↓ from no choice picks the first row; ↑ from the first goes back to
    /// no choice.
    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let next = (selectedIndex ?? -1) + delta
        selectedIndex = next < 0 ? nil : min(next, suggestions.count - 1)
        syncSelection()
    }

    private func syncSelection() {
        // The ⇥ mark follows tabTarget.
        if !suggestions.isEmpty {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<suggestions.count), columnIndexes: [0])
        }
        if let selectedIndex {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        } else {
            tableView.deselectAll(nil)
            tableView.scrollRowToVisible(0)
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard suggestions.indices.contains(row) else { return }
        onPick?(suggestions[row])
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        suggestions.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SuggestionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SuggestionCellView.identifier, owner: self) as? SuggestionCellView
            ?? SuggestionCellView(frame: .zero)
        let suggestion = suggestions[row]
        let workflow = suggestion.workflow
        cell.keyword.stringValue = workflow.takesArgument ? "\(suggestion.keyword) …" : suggestion.keyword
        cell.title.stringValue = workflow.title
        cell.detail.stringValue = workflow.help ?? workflow.url
        cell.key.stringValue = row == (selectedIndex ?? 0) ? "⇥" : ""
        return cell
    }

    // MARK: Setup

    private func buildContent() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // Clicks still pick rows, but typing keeps going to the input.
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero

        let separator = NSBox()
        separator.boxType = .separator

        for view in [separator, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        // Gives way while the list is hidden at height 0.
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding)
        scrollBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            scrollBottom,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

/// Draws the selection as a rounded accent-colored rect inside the row, and
/// always emphasized: the table never becomes first responder (the input
/// keeps focus), which would otherwise leave it a faint gray.
private final class SuggestionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

private final class SuggestionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SuggestionCell")

    let keyword = NSTextField(labelWithString: "")
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    /// "⇥" on the row Tab would complete.
    let key = NSTextField(labelWithString: "")

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        keyword.font = .systemFont(ofSize: 15, weight: .medium)
        keyword.setContentHuggingPriority(.required, for: .horizontal)
        keyword.setContentCompressionResistancePriority(.required, for: .horizontal)

        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        key.font = .systemFont(ofSize: 13)
        key.alignment = .right
        key.setContentHuggingPriority(.required, for: .horizontal)
        key.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [keyword, title, detail, key] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.maximumNumberOfLines = 1
            addSubview(view)
        }
        updateColors()

        NSLayoutConstraint.activate([
            keyword.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SuggestionListView.textInset),
            keyword.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            title.leadingAnchor.constraint(equalTo: keyword.trailingAnchor, constant: 8),
            title.firstBaselineAnchor.constraint(equalTo: keyword.firstBaselineAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -8),

            detail.leadingAnchor.constraint(equalTo: keyword.leadingAnchor),
            detail.topAnchor.constraint(equalTo: keyword.bottomAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -8),

            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            key.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        keyword.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        title.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        detail.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : .tertiaryLabelColor
        key.textColor = selected ? .alternateSelectedControlTextColor : .tertiaryLabelColor
    }
}
