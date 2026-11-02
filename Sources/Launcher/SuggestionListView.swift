// SuggestionListView.swift
//
// The list under the launcher input: installed apps matching what is typed
// and workflows whose keyword starts with it, one row each with an icon, a
// title and a subtitle. The input keeps focus: LauncherController routes
// Tab, ↑ ↓ and ⌘1 to ⌘9 here.

import Cocoa

/// A row in the launcher's list.
enum LauncherItem {
    case workflow(Suggestion)
    case app(AppEntry)

    /// What Tab puts in the field.
    var completion: String {
        switch self {
        case .workflow(let suggestion): suggestion.completion
        case .app(let app): app.name
        }
    }
}

@MainActor
final class SuggestionListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 48
    /// More rows than this scroll.
    static let maxVisibleRows = DigitShortcuts.count
    /// Space above and below the rows.
    static let padding: CGFloat = 6
    /// Where the row icon starts: its center lines up with the input's icon.
    static let iconInset: CGFloat = 16
    static let iconSize: CGFloat = 32
    /// Where the title starts, lined up with the text in the input above.
    static let textInset: CGFloat = 58

    /// A row was clicked.
    var onPick: ((LauncherItem) -> Void)?

    private(set) var items: [LauncherItem] = []
    /// The highlighted row, which Enter takes; nil when Enter runs what is
    /// typed instead.
    private var selectedIndex: Int?
    /// Where ↑ stops: 0 when the first row is what Enter would run anyway
    /// (the matching app), so it stays highlighted; nil otherwise.
    private var floorIndex: Int?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    /// Row icons by app path or URL scheme; emptied with the list.
    private var iconCache: [String: NSImage] = [:]

    /// The highlighted row, if any.
    var selected: LauncherItem? { selectedIndex.map { items[$0] } }

    /// What Tab completes: the highlighted row, else the first.
    var tabTarget: LauncherItem? { selected ?? items.first }

    /// The height that shows the rows (up to maxVisibleRows), 0 when empty.
    var preferredHeight: CGFloat {
        guard !items.isEmpty else { return 0 }
        return CGFloat(min(items.count, Self.maxVisibleRows)) * Self.rowHeight + 2 * Self.padding
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Replaces the rows. `highlightFirst` keeps the first row highlighted
    /// (it is what Enter runs anyway); otherwise nothing is until ↓.
    func show(_ items: [LauncherItem], highlightFirst: Bool = false) {
        self.items = items
        if items.isEmpty { iconCache.removeAll() }
        floorIndex = highlightFirst && !items.isEmpty ? 0 : nil
        selectedIndex = floorIndex
        tableView.reloadData()
        syncSelection()
    }

    /// ↓ from no highlight picks the first row; ↑ from the first goes back
    /// to no highlight, unless the first row stays highlighted.
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = (selectedIndex ?? -1) + delta
        selectedIndex = next < 0 ? floorIndex : min(next, items.count - 1)
        syncSelection()
    }

    /// The row ⌘<number> picks, if there is one.
    func item(number: Int) -> LauncherItem? {
        items.indices.contains(number - 1) ? items[number - 1] : nil
    }

    private func syncSelection() {
        // The ↩ / ⌘N marks follow the highlight.
        if !items.isEmpty {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<items.count), columnIndexes: [0])
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
        guard items.indices.contains(row) else { return }
        onPick?(items[row])
    }

    // MARK: Icons

    private func icon(for item: LauncherItem) -> NSImage? {
        switch item {
        case .app(let app):
            let path = app.url.path
            if let cached = iconCache[path] { return cached }
            let image = NSWorkspace.shared.icon(forFile: path)
            iconCache[path] = image
            return image
        case .workflow(let suggestion):
            return workflowIcon(for: suggestion.workflow)
        }
    }

    /// The icon of the app that opens the workflow's URL (the default
    /// browser for web links), alfresco's own for alfresco:// URLs, else a
    /// link symbol.
    private func workflowIcon(for workflow: Workflow) -> NSImage? {
        let template = workflow.url.replacingOccurrences(of: "{query}", with: "x")
        guard let url = URL(string: template), let scheme = url.scheme?.lowercased() else {
            return NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        }
        if let cached = iconCache[scheme] { return cached }
        let image: NSImage?
        if scheme == "alfresco" {
            image = NSApp.applicationIconImage
        } else if let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            image = NSWorkspace.shared.icon(forFile: app.path)
        } else {
            image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        }
        iconCache[scheme] = image
        return image
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SuggestionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SuggestionCellView.identifier, owner: self) as? SuggestionCellView
            ?? SuggestionCellView(frame: .zero)
        let item = items[row]
        switch item {
        case .app(let app):
            cell.title.stringValue = app.name
            cell.detail.stringValue = (app.url.path as NSString).abbreviatingWithTildeInPath
        case .workflow(let suggestion):
            let workflow = suggestion.workflow
            let keyword = workflow.takesArgument ? "\(suggestion.keyword) …" : suggestion.keyword
            cell.title.stringValue = workflow.title
            cell.detail.stringValue = "\(keyword)  ·  \(workflow.help ?? workflow.url)"
        }
        cell.icon.image = icon(for: item)
        if row == selectedIndex {
            cell.key.stringValue = "↩"
        } else {
            cell.key.stringValue = row < DigitShortcuts.count ? "⌘\(row + 1)" : ""
        }
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

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Gives way while the list is hidden at height 0.
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding)
        scrollBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            scrollBottom,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

/// Draws the highlight as a rounded accent-colored rect inside the row, and
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
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

private final class SuggestionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SuggestionCell")

    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    /// "↩" on the highlighted row, "⌘N" on the other first nine.
    let key = NSTextField(labelWithString: "")

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        icon.imageScaling = .scaleProportionallyUpOrDown
        // Only tints the SF Symbol fallback; app icons keep their colors.
        icon.contentTintColor = .secondaryLabelColor

        title.font = .systemFont(ofSize: 17)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.font = .systemFont(ofSize: 12)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        key.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        key.alignment = .right
        key.setContentHuggingPriority(.required, for: .horizontal)
        key.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [title, detail, key] {
            view.maximumNumberOfLines = 1
        }
        for view in [icon, title, detail, key] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        updateColors()

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SuggestionListView.iconInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SuggestionListView.iconSize),
            icon.heightAnchor.constraint(equalToConstant: SuggestionListView.iconSize),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SuggestionListView.textInset),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -12),

            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 0),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -12),

            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            key.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let onAccent = NSColor.alternateSelectedControlTextColor
        title.textColor = selected ? onAccent : .labelColor
        detail.textColor = selected ? onAccent.withAlphaComponent(0.8) : .secondaryLabelColor
        key.textColor = selected ? onAccent : .controlAccentColor
    }
}
