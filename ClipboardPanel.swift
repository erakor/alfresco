// ClipboardPanel.swift
//
// The clipboard history panel (Config.clipboardHotKey). Type to filter,
// ↑/↓ to choose, ↩ (or double-click) to put the item back on the clipboard,
// then paste with ⌘V as usual. ⌘⌫ deletes the selected item.

import Cocoa

@MainActor
final class ClipboardController: FloatingPanelController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Layout {
        static let size = NSSize(width: 680, height: 440)
        static let headerHeight: CGFloat = 60
        static let footerHeight: CGFloat = 32
        static let rowHeight: CGFloat = 44
    }

    private let store: ClipboardStore
    private let monitor: ClipboardMonitor

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let countLabel = FloatingPanelController.makeHintLabel()
    private let hintLabel = FloatingPanelController.makeHintLabel()

    /// The store's items that match the search field, newest first.
    private var visibleItems: [ClipItem] = []

    private let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    init(store: ClipboardStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
        super.init(size: Layout.size, verticalOffset: 0.08)
        buildContent()

        store.onChange = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.reload(keepingSelection: true)
        }
    }

    override var initialFirstResponder: NSResponder? { searchField }

    override func prepareToShow() {
        store.expireOldItems()
        searchField.stringValue = ""
        reload(keepingSelection: false)
    }

    override func didHide() {
        searchField.stringValue = ""
    }

    // MARK: Data

    private func reload(keepingSelection: Bool) {
        let selectedID = keepingSelection ? selectedItem?.id : nil

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleItems = query.isEmpty
            ? store.items
            : store.items.filter { $0.content.matches(query) }
        tableView.reloadData()

        let row = selectedID.flatMap { id in visibleItems.firstIndex { $0.id == id } } ?? 0
        select(row: row)

        updateLabels(query: query)
    }

    private var selectedItem: ClipItem? {
        let row = tableView.selectedRow
        return visibleItems.indices.contains(row) ? visibleItems[row] : nil
    }

    private func select(row: Int) {
        guard !visibleItems.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        let row = min(max(row, 0), visibleItems.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func updateLabels(query: String) {
        let hours = Int((Config.clipboardRetention / 3600).rounded())
        emptyLabel.stringValue = query.isEmpty
            ? "Nothing copied in the last \(hours) hours"
            : "No matches"
        emptyLabel.isHidden = !visibleItems.isEmpty

        let total = store.items.count
        let noun = total == 1 ? "item" : "items"
        countLabel.stringValue = query.isEmpty || visibleItems.count == total
            ? "\(total) \(noun)"
            : "\(visibleItems.count) of \(total) \(noun)"

        hintLabel.stringValue = visibleItems.isEmpty
            ? "esc to close"
            : "↩ copy · ⌘⌫ delete · esc close"
    }

    // MARK: Actions

    /// Puts the selected item on the clipboard and closes the panel; the user
    /// then pastes with ⌘V in the app they were using.
    private func copySelected() {
        guard let item = selectedItem else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.content {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        }
        monitor.ignoreCurrentContents()
        store.promote(id: item.id)
        hide()
    }

    private func deleteSelected() {
        guard let item = selectedItem else { return }
        let row = tableView.selectedRow
        store.remove(id: item.id)
        // onChange has reloaded the list; keep the cursor on the same row.
        select(row: row)
    }

    @objc private func rowDoubleClicked() {
        guard tableView.clickedRow >= 0 else { return }
        select(row: tableView.clickedRow)
        copySelected()
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        reload(keepingSelection: false)
    }

    /// Focus never leaves the search field, so it routes the list's keys.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            select(row: tableView.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)):
            select(row: tableView.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)):
            copySelected()
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):  // ⌘⌫
            deleteSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
        default:
            return false
        }
        return true
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleItems.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ClipCellView.identifier, owner: self) as? ClipCellView
            ?? ClipCellView(frame: .zero)
        let item = visibleItems[row]

        switch item.content {
        case .text(let text):
            cell.title.stringValue = Self.preview(of: text)

            var details: [String] = []
            if let app = item.sourceApp { details.append(app) }
            details.append(ageFormatter.localizedString(for: item.copiedAt, relativeTo: Date()))
            let lines = text.utf8.lazy.filter { $0 == UInt8(ascii: "\n") }.count + 1
            if lines > 1 { details.append("\(lines) lines") }
            cell.detail.stringValue = details.joined(separator: " · ")
        }
        return cell
    }

    /// First line's worth of text with runs of whitespace collapsed.
    private static func preview(of text: String) -> String {
        text.prefix(400)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: Setup

    private func buildContent() {
        let icon = Self.makeIcon(symbolName: "doc.on.clipboard")

        Self.styleSearchField(searchField, placeholder: "Search clipboard history…")
        searchField.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Layout.rowHeight
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // Clicks still select rows, but typing keeps going to the search field.
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator

        hintLabel.alignment = .right

        for view in [icon, searchField, topSeparator, scrollView, emptyLabel, bottomSeparator, countLabel, hintLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        let header = contentView.topAnchor
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: header, constant: Layout.headerHeight / 2),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            searchField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            searchField.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            topSeparator.topAnchor.constraint(equalTo: header, constant: Layout.headerHeight),
            topSeparator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor, constant: -4),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            bottomSeparator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.footerHeight),
            bottomSeparator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            countLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            countLabel.centerYAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.footerHeight / 2),

            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            hintLabel.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
        ])
    }
}

// MARK: - Rows

/// Always draws the selection in the accent color: the table never becomes
/// first responder (the search field keeps focus), which would otherwise
/// leave the selection a faint gray.
private final class ClipRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class ClipCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ClipCell")

    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        // NSTableCellView adapts textField's color to the selection itself.
        textField = title

        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            detail.textColor = backgroundStyle == .emphasized
                ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75)
                : .secondaryLabelColor
        }
    }
}
