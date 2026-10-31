// ClipboardPanel.swift
//
// The clipboard history panel (Config.clipboardHotKey). Type to filter,
// ↑/↓ to choose, ↩ (or double-click) to put the item back on the clipboard,
// then paste with ⌘V as usual. ⌘⌫ deletes the selected item. The selected
// item is shown in full on the right: text, the image, or the file.

import Cocoa
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ClipboardController: FloatingPanelController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Layout {
        static let size = NSSize(width: 820, height: 480)
        static let headerHeight: CGFloat = 60
        static let footerHeight: CGFloat = 32
        static let rowHeight: CGFloat = 44
        static let listWidth: CGFloat = 380
        /// Longest side of the image shown in the preview, in pixels.
        static let previewPixelSize = 1200
    }

    private let store: ClipboardStore
    private let monitor: ClipboardMonitor

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let countLabel = FloatingPanelController.makeHintLabel()
    private let hintLabel = FloatingPanelController.makeHintLabel()
    private let preview = ClipPreviewView()

    /// Row thumbnails, app icons and previews. Emptied when the panel closes,
    /// so edited files and uninstalled apps show up fresh next time.
    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    /// The store's items that match the search field, newest first.
    private var visibleItems: [ClipItem] = []

    private let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// "Today at 13:31".
    private let copiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
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
        imageCache.removeAllObjects()
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
        // Selecting the same row again posts no selection change, but the
        // item in it may be a different one.
        updatePreview()
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
        guard write(item.content, to: NSPasteboard.general) else {
            // The image file or every copied file is gone.
            NSSound.beep()
            return
        }
        monitor.ignoreCurrentContents()
        store.promote(id: item.id)
        hide()
    }

    /// Returns false, leaving the clipboard alone, when there's nothing left
    /// to put back.
    private func write(_ content: ClipContent, to pasteboard: NSPasteboard) -> Bool {
        switch content {
        case .text(let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

        case .image(let image):
            guard let png = store.imageData(for: image) else { return false }
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            // Some older apps only read TIFF. It is uncompressed (about 60 MB
            // for a 5K screenshot), so only smaller images get a copy.
            if image.pixelWidth * image.pixelHeight <= 4_000_000,
               let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])

        case .files(let paths):
            let urls = paths
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return false }
            // Like Finder: the files, plus their names for pasting as text.
            let items = urls.enumerated().map { index, url -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                if index == 0 {
                    item.setString(urls.map(\.lastPathComponent).joined(separator: "\n"), forType: .string)
                }
                return item
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
        }
        return true
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

        var details: [String] = []
        if let app = item.sourceApp { details.append(app) }
        details.append(ageFormatter.localizedString(for: item.copiedAt, relativeTo: Date()))

        switch item.content {
        case .text(let text):
            cell.title.stringValue = Self.preview(of: text)
            cell.icon.image = item.sourceBundleID.flatMap { appIcon(bundleID: $0) }
                ?? NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil)
            let lines = text.utf8.lazy.filter { $0 == UInt8(ascii: "\n") }.count + 1
            if lines > 1 { details.append("\(lines) lines") }

        case .image(let image):
            cell.title.stringValue = "Image: \(image.dimensions)"
            cell.icon.image = thumbnail(of: store.imageURL(for: image), maxPixelSize: 96)
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            details.append(Self.byteCount(image.byteCount))

        case .files(let paths):
            cell.title.stringValue = Self.title(ofFiles: paths)
            cell.icon.image = fileIcon(paths)
            let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
            if existing.isEmpty {
                details.append(paths.count == 1 ? "no longer there" : "none are still there")
            } else {
                details.append(Self.abbreviated((paths[0] as NSString).deletingLastPathComponent))
            }
        }

        cell.detail.stringValue = details.joined(separator: " · ")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    // MARK: Preview

    private func updatePreview() {
        guard let item = selectedItem else {
            preview.clear()
            return
        }

        var copied = "Copied \(copiedFormatter.string(from: item.copiedAt))"
        if let app = item.sourceApp { copied += " from \(app)" }
        var info = [copied]

        switch item.content {
        case .text(let text):
            preview.showText(text)
            let characters = text.count
            info.append(characters == 1 ? "1 character" : "\(characters) characters")

        case .image(let image):
            preview.showImage(thumbnail(of: store.imageURL(for: image), maxPixelSize: Layout.previewPixelSize), path: nil)
            info.append(image.dimensions)
            info.append(Self.byteCount(image.byteCount))

        case .files(let paths):
            let location = paths.count == 1
                ? Self.abbreviated(paths[0])
                : "\(Self.abbreviated(paths[0])) and \(paths.count - 1) more"
            preview.showImage(filePreview(paths), path: location)
            let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }.count
            if missing > 0 {
                info.append(paths.count == 1 ? "no longer there" : "\(missing) no longer there")
            }
        }

        preview.info.stringValue = info.joined(separator: " · ")
    }

    /// A picture of the file when it is an image, otherwise its icon.
    private func filePreview(_ paths: [String]) -> NSImage {
        if paths.count == 1 {
            let url = URL(fileURLWithPath: paths[0])
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            if type?.conforms(to: .image) == true,
               let image = thumbnail(of: url, maxPixelSize: Layout.previewPixelSize) {
                return image
            }
        }
        let icon = fileIcon(paths)
        icon.size = NSSize(width: 256, height: 256)
        return icon
    }

    // MARK: Images

    /// Downsampled with ImageIO, so a large image is never decoded in full.
    private func thumbnail(of url: URL, maxPixelSize: Int) -> NSImage? {
        cachedImage(key: "thumb:\(maxPixelSize):\(url.path)") {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: .zero)
        }
    }

    private func fileIcon(_ paths: [String]) -> NSImage {
        // Not cached: callers resize it.
        paths.count == 1
            ? NSWorkspace.shared.icon(forFile: paths[0])
            : NSWorkspace.shared.icon(forFiles: paths) ?? NSWorkspace.shared.icon(for: .data)
    }

    private func appIcon(bundleID: String) -> NSImage? {
        cachedImage(key: "app:\(bundleID)") {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }

    private func cachedImage(key: String, make: () -> NSImage?) -> NSImage? {
        if let image = imageCache.object(forKey: key as NSString) { return image }
        guard let image = make() else { return nil }
        imageCache.setObject(image, forKey: key as NSString)
        return image
    }

    // MARK: Formatting

    /// First line's worth of text with runs of whitespace collapsed.
    private static func preview(of text: String) -> String {
        text.prefix(400)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func title(ofFiles paths: [String]) -> String {
        let names = paths.map { (($0 as NSString).lastPathComponent) }
        guard paths.count == 1 else {
            return "\(paths.count) files: \(names.joined(separator: ", "))"
        }
        var isDirectory: ObjCBool = false
        let isFolder = FileManager.default.fileExists(atPath: paths[0], isDirectory: &isDirectory) && isDirectory.boolValue
        return "\(isFolder ? "Folder" : "File"): \(names[0])"
    }

    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
        let middleSeparator = NSBox()
        middleSeparator.boxType = .separator

        hintLabel.alignment = .right

        let views = [
            icon, searchField, topSeparator, scrollView, emptyLabel, middleSeparator, preview,
            bottomSeparator, countLabel, hintLabel,
        ]
        for view in views {
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
            scrollView.widthAnchor.constraint(equalToConstant: Layout.listWidth),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor, constant: -4),

            middleSeparator.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            middleSeparator.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            middleSeparator.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            middleSeparator.widthAnchor.constraint(equalToConstant: 1),

            preview.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 12),
            preview.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor, constant: -10),
            preview.leadingAnchor.constraint(equalTo: middleSeparator.trailingAnchor, constant: 16),
            preview.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

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

    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        // NSTableCellView adapts textField's color to the selection itself.
        textField = title

        icon.imageScaling = .scaleProportionallyUpOrDown
        // Only tints the SF Symbol fallbacks; app icons and thumbnails keep their colors.
        icon.contentTintColor = .secondaryLabelColor

        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [icon, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
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

// MARK: - Preview

/// The right-hand side of the panel: the selected item in full, with when and
/// where it was copied underneath.
private final class ClipPreviewView: NSView {
    /// "Copied Today at 13:31 from Safari · 1920 × 1080 · 240 KB".
    let info = NSTextField(labelWithString: "")

    /// Where a copied file lives, above its picture.
    private let pathLabel = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let textScroll = NSTextView.scrollableTextView()
    private var textView: NSTextView? { textScroll.documentView as? NSTextView }
    /// The image starts below the path when there is one, at the top otherwise.
    private lazy var imageBelowPath = imageView.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 12)
    private lazy var imageAtTop = imageView.topAnchor.constraint(equalTo: topAnchor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        if let textView {
            textView.drawsBackground = false
            textView.isEditable = false
            // Not selectable, so clicks never take focus from the search field.
            textView.isSelectable = false
            textView.font = .systemFont(ofSize: 13)
            textView.textColor = .labelColor
            textView.textContainerInset = .zero
        }

        info.font = .systemFont(ofSize: 12)
        info.textColor = .tertiaryLabelColor
        info.alignment = .center
        info.lineBreakMode = .byTruncatingTail
        info.maximumNumberOfLines = 1
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [pathLabel, imageView, textScroll, info] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            pathLabel.topAnchor.constraint(equalTo: topAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            imageAtTop,
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -12),

            textScroll.topAnchor.constraint(equalTo: topAnchor),
            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -10),

            info.leadingAnchor.constraint(equalTo: leadingAnchor),
            info.trailingAnchor.constraint(equalTo: trailingAnchor),
            info.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        clear()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func showText(_ text: String) {
        isHidden = false
        pathLabel.isHidden = true
        imageView.isHidden = true
        imageView.image = nil
        textScroll.isHidden = false
        textView?.string = text
        textView?.scroll(.zero)
    }

    /// `path` is shown above the image when given (for files).
    func showImage(_ image: NSImage?, path: String?) {
        isHidden = false
        textScroll.isHidden = true
        textView?.string = ""
        pathLabel.isHidden = path == nil
        pathLabel.stringValue = path ?? ""
        imageAtTop.isActive = path == nil
        imageBelowPath.isActive = path != nil
        imageView.isHidden = false
        imageView.image = image
    }

    func clear() {
        isHidden = true
        imageView.image = nil
        textView?.string = ""
        info.stringValue = ""
    }
}
