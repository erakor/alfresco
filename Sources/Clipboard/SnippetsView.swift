// SnippetsView.swift
//
// The snippets area under the launcher input, shown while the input runs the
// `/snip` workflow (alfresco://snippet/{query}), with or without a name: the
// snippets whose name starts with what is typed, the one Enter pastes
// highlighted. The launcher's hint says what Enter does (Snippets.hint).

import Cocoa

/// What the view shows, worked out without AppKit so the self-test can
/// check it.
struct SnippetsViewContent: Equatable {
    struct Row: Equatable {
        let name: String
        let preview: String
        let symbolName: String
        /// The one Enter pastes.
        let highlighted: Bool
    }

    let rows: [Row]
    /// "3 more", or what to do when nothing is listed; nil for nothing.
    let footer: String?

    /// At most this many rows; the rest are counted in the footer.
    static let maxRows = 6

    /// `typed` is what follows the keyword (empty for `/snip` alone).
    init(typed: String, items: [ClipItem]) {
        let found = Snippets.matches(typed, in: items)
        let pasted = Snippets.resolve(typed, in: items)?.id
        rows = found.prefix(Self.maxRows).map { item in
            Row(
                name: item.snippetName ?? "",
                preview: Snippets.preview(of: item.content),
                symbolName: Self.symbolName(of: item.content),
                highlighted: item.id == pasted
            )
        }
        if found.count > Self.maxRows {
            footer = "\(found.count - Self.maxRows) more"
        } else if found.isEmpty {
            footer = Snippets.all(in: items).isEmpty
                ? "No snippets yet: in the clipboard history, ⌘S names the selected clip"
                : "No snippet starts with \(typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        } else {
            footer = nil
        }
    }

    private static func symbolName(of content: ClipContent) -> String {
        switch content {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc"
        }
    }
}

final class SnippetsView: NSView {
    private static let padding: CGFloat = 8
    private static let rowHeight: CGFloat = 28
    private static let footerHeight: CGFloat = 24

    private let separator = NSBox()
    private let stack = NSStackView()
    private let footerLabel = NSTextField.areaLabel(size: 12, color: .secondaryLabelColor)
    private var shown: SnippetsViewContent?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Height the launcher adds below its input row for what is shown.
    var preferredHeight: CGFloat {
        guard let shown else { return 0 }
        let rows = CGFloat(shown.rows.count) * Self.rowHeight
        let footer = shown.footer == nil ? 0 : Self.footerHeight
        return Self.padding * 2 + rows + footer
    }

    /// Rebuilt only when the content changed.
    func show(_ content: SnippetsViewContent) {
        guard content != shown else { return }
        shown = content
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for row in content.rows {
            let view = makeRow(row)
            stack.addArrangedSubview(view)
            // Full width, so the highlight spans the row.
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        footerLabel.stringValue = content.footer ?? ""
        footerLabel.isHidden = content.footer == nil
        stack.addArrangedSubview(footerLabel)
    }

    #if SELFTEST
    /// What the view shows, for the self-test.
    var contentForSelfTest: SnippetsViewContent? { shown }
    #endif

    private func makeRow(_ row: SnippetsViewContent.Row) -> NSView {
        let view = NSView()
        // A box rather than a layer color, so it follows light and dark mode.
        let background = NSBox()
        background.boxType = .custom
        background.borderWidth = 0
        background.cornerRadius = 6
        background.fillColor = row.highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.18) : .clear
        let icon = NSImageView(image: NSImage(systemSymbolName: row.symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField.areaLabel(row.name, size: 13, color: .labelColor, weight: .semibold)
        name.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        name.setContentHuggingPriority(.required, for: .horizontal)
        let preview = NSTextField.areaLabel(row.preview, size: 13, color: .secondaryLabelColor)
        preview.toolTip = row.preview
        for subview in [background, icon, name, preview] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            preview.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 12),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            preview.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    private func build() {
        separator.boxType = .separator
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.distribution = .fill
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        for view in [separator, stack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerLabel.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
    }
}
