// TransitMenuView.swift
//
// What the transit menu bar item's menu shows: the launcher's departure
// board (TransitView, without its top line), then the station's service
// alerts, incidents first (the service's order), planned work dimmed. Laid
// out by hand in a fixed width; its height follows the content, and the
// menu follows its frame.

import Cocoa

final class TransitMenuView: NSView {
    static let width: CGFloat = 400
    /// The board while it shows only a status line (loading, failed).
    static let statusHeight: CGFloat = 52
    /// Alerts listed; a line counts the rest.
    static let maxAlerts = 4
    private static let inset: CGFloat = 14

    private let board = TransitView(frame: .zero)
    private let alertsSeparator = NSBox()
    private let alertsTitle = NSTextField.areaLabel(size: 11, color: .secondaryLabelColor, weight: .medium)
    private var rows: [AlertRow] = []
    private let moreLabel = NSTextField.areaLabel(size: 11, color: .tertiaryLabelColor)

    #if SELFTEST
    /// The board last shown, nil while loading or failed.
    var boardForSelfTest: TransitBoard? { board.boardForSelfTest }
    /// The alerts section's title, nil while hidden.
    var alertsTitleForSelfTest: String? { alertsTitle.isHidden ? nil : alertsTitle.stringValue }
    /// Each alert row's first line (its status).
    var alertRowsForSelfTest: [String] { rows.filter { !$0.isHidden }.map(\.categoryText) }
    /// The line counting alerts not listed, nil while hidden.
    var moreForSelfTest: String? { moreLabel.isHidden ? nil : moreLabel.stringValue }
    #endif

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.statusHeight))
        board.showsSeparator = false
        alertsSeparator.boxType = .separator
        rows = (0..<Self.maxAlerts).map { _ in AlertRow(frame: .zero) }
        for view in [board, alertsSeparator, alertsTitle, moreLabel] as [NSView] {
            addSubview(view)
        }
        for row in rows { addSubview(row) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The board in `state` at `now`, then `alerts` (no section before the
    /// first answer), and sizes the view to fit.
    func show(_ state: TransitState, alerts: TransitAlerts?, now: Date) {
        board.show(state, now: now)
        let width = Self.width - Self.inset * 2
        var loaded = false
        if case .loaded = state { loaded = true }
        let boardHeight = loaded ? TransitView.height : Self.statusHeight
        board.frame = NSRect(x: Self.inset, y: 4, width: width, height: boardHeight)
        var y = board.frame.maxY

        let list = alerts?.alerts ?? []
        let showsAlerts = alerts != nil
        alertsSeparator.isHidden = !showsAlerts
        alertsTitle.isHidden = !showsAlerts
        if let alerts {
            alertsSeparator.frame = NSRect(x: Self.inset, y: y + 2, width: width, height: 1)
            y += 12
            alertsTitle.stringValue = alerts.summary.uppercased()
            alertsTitle.sizeToFit()
            alertsTitle.frame = NSRect(x: Self.inset, y: y, width: width, height: alertsTitle.frame.height)
            y = alertsTitle.frame.maxY + 6
        }
        for (index, row) in rows.enumerated() {
            guard index < list.count else {
                row.isHidden = true
                continue
            }
            row.isHidden = false
            let height = row.fill(with: list[index], width: width)
            row.frame = NSRect(x: Self.inset, y: y, width: width, height: height)
            y += height + 10
        }
        let rest = list.count - rows.count
        moreLabel.isHidden = rest <= 0
        if rest > 0 {
            moreLabel.stringValue = rest == 1 ? "1 more alert" : "\(rest) more alerts"
            moreLabel.sizeToFit()
            moreLabel.frame = NSRect(x: Self.inset, y: y, width: width, height: moreLabel.frame.height)
            y = moreLabel.frame.maxY + 6
        }
        setFrameSize(NSSize(width: Self.width, height: ceil(y + 6)))
    }

    /// What an alert's first line says: the MTA's status, else what kind
    /// of alert it is.
    static func categoryText(of alert: TransitAlert) -> String {
        if let category = alert.category, !category.isEmpty { return category }
        return alert.planned ? "Planned work" : "Service alert"
    }
}

/// One alert: its routes' bullets and status on the first line, then its
/// text, wrapped on up to four lines. Planned work is dimmed.
private final class AlertRow: NSView {
    private static let bulletSide: CGFloat = 16
    private static let maxBullets = 8
    private static let firstLineHeight: CGFloat = 18
    private static let maxTextHeight: CGFloat = 64

    private var bullets: [RouteBullet] = []
    private let categoryLabel = NSTextField.areaLabel(size: 11, color: .secondaryLabelColor, weight: .semibold)
    private let headerLabel = NSTextField(wrappingLabelWithString: "")

    var categoryText: String { categoryLabel.stringValue }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headerLabel.font = .systemFont(ofSize: 12)
        headerLabel.maximumNumberOfLines = 4
        headerLabel.cell?.truncatesLastVisibleLine = true
        headerLabel.isSelectable = false
        bullets = (0..<Self.maxBullets).map { _ in RouteBullet(frame: .zero) }
        for bullet in bullets { addSubview(bullet) }
        addSubview(categoryLabel)
        addSubview(headerLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Lays out `alert` in `width`; returns the height it takes.
    func fill(with alert: TransitAlert, width: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        let side = Self.bulletSide
        for (index, bullet) in bullets.enumerated() {
            guard index < alert.routes.count else {
                bullet.isHidden = true
                continue
            }
            let route = alert.routes[index]
            bullet.isHidden = false
            bullet.show(route: route.name, color: route.color, textColor: route.textColor)
            bullet.frame = NSRect(x: x, y: (Self.firstLineHeight - side) / 2, width: side, height: side)
            x += side + 3
        }
        if x > 0 { x += 3 }

        categoryLabel.stringValue = TransitMenuView.categoryText(of: alert)
        categoryLabel.textColor = alert.planned ? .tertiaryLabelColor : .secondaryLabelColor
        categoryLabel.sizeToFit()
        let labelHeight = categoryLabel.frame.height
        categoryLabel.frame = NSRect(
            x: x, y: (Self.firstLineHeight - labelHeight) / 2,
            width: max(0, min(categoryLabel.frame.width, width - x)), height: labelHeight
        )

        headerLabel.stringValue = alert.header
        headerLabel.textColor = alert.planned ? .secondaryLabelColor : .labelColor
        headerLabel.toolTip = alert.header
        headerLabel.preferredMaxLayoutWidth = width
        let fit = headerLabel.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        let textHeight = min(ceil(fit.height), Self.maxTextHeight)
        headerLabel.frame = NSRect(x: 0, y: Self.firstLineHeight + 2, width: width, height: textHeight)
        return Self.firstLineHeight + 2 + textHeight
    }
}
