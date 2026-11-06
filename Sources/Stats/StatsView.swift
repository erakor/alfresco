// StatsView.swift
//
// The `/stats` area under the launcher input: a title ("Last 7 days"),
// four figures (commands run, apps opened, clips restored, focus
// sessions), the most run commands and the most opened apps side by side
// with a bar for each count, and a line naming the commands never run.
// Fixed height; rebuilt only when the report changed.

import Cocoa

@MainActor
final class StatsView: NSView {
    private static let padding: CGFloat = 8
    private static let titleHeight: CGFloat = 16
    private static let tileHeight: CGFloat = 54
    private static let footerHeight: CGFloat = 20
    /// Room for a full list, so the panel keeps its height as lists fill up.
    private static let listHeight = titleHeight + 4 + CGFloat(UsageReport.listLimit) * StatsList.rowHeight
    /// Height the launcher adds below its input row.
    static let height: CGFloat = 1 + padding + titleHeight + 6 + tileHeight + 14 + listHeight + 8 + footerHeight + 12

    private let separator = NSBox()
    private let titleLabel = NSTextField.areaLabel(size: 10, color: .secondaryLabelColor, weight: .semibold)
    private let commandsTile = StatsTile(caption: "Commands run")
    private let appsTile = StatsTile(caption: "Apps opened")
    private let clipsTile = StatsTile(caption: "Clips restored")
    private let focusTile = StatsTile(caption: "Focus sessions")
    private let commandsList = StatsList(title: "TOP COMMANDS", empty: "No command run")
    private let appsList = StatsList(title: "TOP APPS", empty: "No app opened from here")
    private let unusedLabel = NSTextField.areaLabel(size: 12, color: .secondaryLabelColor)
    private var shown: UsageReport?
    /// Workflow icons by URL scheme (WorkflowIcon), app icons by bundle ID.
    /// Kept while the app runs: a handful of each.
    private var workflowIcons: [String: NSImage] = [:]
    private var appIcons: [String: NSImage] = [:]

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows `report`; `workflows` gives the commands their icons.
    func show(_ report: UsageReport, workflows: WorkflowSet) {
        guard report != shown else { return }
        shown = report
        titleLabel.stringValue = UsageReport.title(
            days: report.days, since: report.countingSince.map(Self.dayFormatter.string(from:))
        ).uppercased()
        commandsTile.value = report.commandsRun
        appsTile.value = report.appsOpened
        clipsTile.value = report.clipsRestored
        focusTile.value = report.focusSessions
        commandsList.show(report.topCommands) { commandIcon($0, workflows: workflows) }
        appsList.show(report.topApps) { appIcon($0) }
        let unused = UsageReport.unusedLine(
            report.unusedCommands, since: report.unusedSince.map(Self.dayFormatter.string(from:)),
            retentionDays: Config.usageRetentionDays
        )
        unusedLabel.stringValue = unused
        unusedLabel.toolTip = report.unusedCommands.isEmpty ? nil : unused
    }

    #if SELFTEST
    /// The report the labels show, for the self-test.
    var reportForSelfTest: UsageReport? { shown }
    #endif

    /// The icon of the app that opens the keyword's URL, as in the
    /// suggestion list; a symbol for a keyword no longer in workflows.json.
    private func commandIcon(_ entry: UsageReport.Entry, workflows: WorkflowSet) -> NSImage? {
        let workflow = workflows.workflow(for: entry.key, withArgument: false)
            ?? workflows.workflow(for: entry.key, withArgument: true)
        guard let workflow else { return NSImage(systemSymbolName: "command", accessibilityDescription: nil) }
        return WorkflowIcon.image(for: workflow, cache: &workflowIcons)
    }

    private func appIcon(_ entry: UsageReport.Entry) -> NSImage? {
        if let cached = appIcons[entry.key] { return cached }
        let image: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.key) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        }
        appIcons[entry.key] = image
        return image
    }

    private func build() {
        separator.boxType = .separator

        let tiles = NSStackView(views: [commandsTile, appsTile, clipsTile, focusTile])
        tiles.orientation = .horizontal
        tiles.distribution = .fillEqually
        tiles.spacing = 8

        let lists = NSStackView(views: [commandsList, appsList])
        lists.orientation = .horizontal
        lists.distribution = .fillEqually
        lists.alignment = .top
        lists.spacing = 24

        for view in [separator, titleLabel, tiles, lists, unusedLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: Self.padding),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleLabel.heightAnchor.constraint(equalToConstant: Self.titleHeight),

            tiles.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            tiles.leadingAnchor.constraint(equalTo: leadingAnchor),
            tiles.trailingAnchor.constraint(equalTo: trailingAnchor),
            tiles.heightAnchor.constraint(equalToConstant: Self.tileHeight),

            lists.topAnchor.constraint(equalTo: tiles.bottomAnchor, constant: 14),
            lists.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            lists.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            lists.heightAnchor.constraint(equalToConstant: Self.listHeight),

            unusedLabel.topAnchor.constraint(equalTo: lists.bottomAnchor, constant: 8),
            unusedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            unusedLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            unusedLabel.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
        for list in [commandsList, appsList] {
            list.heightAnchor.constraint(equalToConstant: Self.listHeight).isActive = true
        }
    }
}

// MARK: - Figure

/// One figure: a big number over its caption, on a tinted rounded box.
@MainActor
private final class StatsTile: NSBox {
    private let valueLabel = NSTextField(labelWithString: "0")
    private let captionLabel = NSTextField.areaLabel(size: 11, color: .secondaryLabelColor)

    var value = 0 {
        didSet { valueLabel.stringValue = "\(value)" }
    }

    init(caption: String) {
        super.init(frame: .zero)
        boxType = .custom
        borderWidth = 0
        cornerRadius = 10
        // NSBox resolves its fill color as it draws, so light and dark mode
        // both follow.
        fillColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
        titlePosition = .noTitle
        contentViewMargins = .zero

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        valueLabel.textColor = .labelColor
        captionLabel.stringValue = caption

        let stack = NSStackView(views: [valueLabel, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

// MARK: - Top list

/// A titled list of at most UsageReport.listLimit lines, each with its
/// icon, name and count over a bar as long as its share of the first line.
@MainActor
private final class StatsList: NSView {
    static let rowHeight: CGFloat = 22

    private let titleLabel = NSTextField.areaLabel(size: 10, color: .secondaryLabelColor, weight: .semibold)
    private let emptyLabel: NSTextField
    private let rows = NSStackView()

    init(title: String, empty: String) {
        emptyLabel = NSTextField.areaLabel(empty, size: 12, color: .tertiaryLabelColor)
        super.init(frame: .zero)
        titleLabel.stringValue = title
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        for view in [titleLabel, rows, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            rows.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),

            emptyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ entries: [UsageReport.Entry], icon: (UsageReport.Entry) -> NSImage?) {
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let most = CGFloat(entries.first?.count ?? 0)
        for entry in entries {
            let row = StatsBarRow(entry: entry, icon: icon(entry), fraction: most > 0 ? CGFloat(entry.count) / most : 0)
            row.translatesAutoresizingMaskIntoConstraints = false
            rows.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: rows.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            ])
        }
        emptyLabel.isHidden = !entries.isEmpty
    }
}

/// One line of a top list: icon, name, count, over a tinted bar.
@MainActor
private final class StatsBarRow: NSView {
    private let fraction: CGFloat

    init(entry: UsageReport.Entry, icon: NSImage?, fraction: CGFloat) {
        self.fraction = fraction
        super.init(frame: .zero)
        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        let name = NSTextField.areaLabel(entry.name, size: 13, color: .labelColor)
        let count = NSTextField(labelWithString: "\(entry.count)")
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        toolTip = "\(entry.name): \(entry.count)"

        for view in [iconView, name, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            name.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),

            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The bar, drawn rather than a layer so its color follows light and
    /// dark mode and the accent color.
    override func draw(_ dirtyRect: NSRect) {
        guard fraction > 0 else { return }
        let rect = NSRect(x: 0, y: 2, width: max(bounds.height, bounds.width * fraction), height: bounds.height - 4)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }
}
