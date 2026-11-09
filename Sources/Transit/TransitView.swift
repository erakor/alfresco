// TransitView.swift
//
// The departure board under the launcher input: the station's name, then
// two columns (uptown, downtown) of the next trains, each a line bullet,
// a countdown and the clock time, and a footer with the snapshot's age.
// Loading and errors use the shared StatusRow. Labels are English.

import Cocoa

final class TransitView: NSView {
    /// Height the launcher adds below its input row while this is shown.
    static let height: CGFloat = 240

    private let titleLabel = NSTextField.areaLabel(size: 13, color: .labelColor, weight: .semibold)
    private let footerLabel = NSTextField.areaLabel(size: 11, color: .tertiaryLabelColor)
    private let columns = [DirectionColumn(frame: .zero), DirectionColumn(frame: .zero)]
    private let columnsStack = NSStackView()
    private let statusRow = StatusRow(frame: .zero)

    #if SELFTEST
    /// The board last shown, nil while loading or failed.
    private(set) var boardForSelfTest: TransitBoard?
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ state: TransitState, station: TransitStation, now: Date) {
        titleLabel.stringValue = station.name
        switch state {
        case .loading:
            setContentVisible(false)
            statusRow.showLoading("Trains at \(station.name)…")
            setBoardForSelfTest(nil)
        case .failed(let message):
            setContentVisible(false)
            statusRow.showMessage(message)
            setBoardForSelfTest(nil)
        case .loaded(let snapshot):
            statusRow.stopSpinner()
            setContentVisible(true)
            let board = TransitBoard.make(from: snapshot, now: now, limit: Config.transitDepartures)
            columns[0].fill(title: station.northLabel, departures: board.north, now: now)
            columns[1].fill(title: station.southLabel, departures: board.south, now: now)
            var footer = "Updated \(TransitBoard.age(of: snapshot.fetchedAt, now: now))"
            if snapshot.missingFeeds > 0 { footer += " · some lines unavailable" }
            footerLabel.stringValue = footer + " · MTA real-time data"
            setBoardForSelfTest(board)
        }
    }

    private func setBoardForSelfTest(_ board: TransitBoard?) {
        #if SELFTEST
        boardForSelfTest = board
        #endif
    }

    private func setContentVisible(_ visible: Bool) {
        columnsStack.isHidden = !visible
        footerLabel.isHidden = !visible
        statusRow.isHidden = visible
    }

    private func build() {
        let separator = NSBox()
        separator.boxType = .separator

        columnsStack.orientation = .horizontal
        columnsStack.distribution = .fillEqually
        columnsStack.alignment = .top
        columnsStack.spacing = 24
        for column in columns { columnsStack.addArrangedSubview(column) }

        for view in [separator, titleLabel, columnsStack, footerLabel, statusRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            columnsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            columnsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnsStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            footerLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            statusRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            statusRow.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

/// One direction: its name, then up to Config.transitDepartures trains.
private final class DirectionColumn: NSStackView {
    private let titleLabel = NSTextField.areaLabel(size: 11, color: .secondaryLabelColor, weight: .medium)
    private let emptyLabel = NSTextField.areaLabel("No trains due", size: 13, color: .tertiaryLabelColor)
    private var rows: [DepartureRow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        rows = (0..<Config.transitDepartures).map { _ in DepartureRow(frame: .zero) }
        var views: [NSView] = [titleLabel, emptyLabel]
        views += rows as [NSView]
        setViews(views, in: .top)
        setCustomSpacing(6, after: titleLabel)
        for row in rows {
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func fill(title: String, departures: [TransitDeparture], now: Date) {
        titleLabel.stringValue = title.uppercased()
        emptyLabel.isHidden = !departures.isEmpty
        for (index, row) in rows.enumerated() {
            if index < departures.count {
                row.isHidden = false
                row.fill(with: departures[index], now: now)
            } else {
                row.isHidden = true
            }
        }
    }
}

/// A line bullet, the countdown, and the clock time on the right.
private final class DepartureRow: NSView {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private let bullet = RouteBullet(frame: .zero)
    private let countdownLabel = NSTextField(labelWithString: "")
    private let clockLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        clockLabel.textColor = .secondaryLabelColor
        for view in [bullet, countdownLabel, clockLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            bullet.leadingAnchor.constraint(equalTo: leadingAnchor),
            bullet.centerYAnchor.constraint(equalTo: centerYAnchor),
            bullet.widthAnchor.constraint(equalToConstant: 20),
            bullet.heightAnchor.constraint(equalToConstant: 20),
            countdownLabel.leadingAnchor.constraint(equalTo: bullet.trailingAnchor, constant: 10),
            countdownLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            clockLabel.leadingAnchor.constraint(greaterThanOrEqualTo: countdownLabel.trailingAnchor, constant: 8),
            clockLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            clockLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func fill(with departure: TransitDeparture, now: Date) {
        bullet.route = departure.route
        countdownLabel.stringValue = TransitBoard.countdown(to: departure.time, now: now)
        clockLabel.stringValue = Self.clock.string(from: departure.time)
    }
}

/// The MTA's round line bullet: the line's color with its letter in white
/// (black on yellow).
private final class RouteBullet: NSView {
    var route = "" {
        didSet { if route != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = TransitBoard.color(of: route)
        let side = min(bounds.width, bounds.height)
        let circle = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        NSColor(
            srgbRed: CGFloat((color.rgb >> 16) & 0xFF) / 255,
            green: CGFloat((color.rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(color.rgb & 0xFF) / 255,
            alpha: 1
        ).setFill()
        NSBezierPath(ovalIn: circle).fill()

        let fontSize: CGFloat = route.count > 1 ? 8 : 12
        let text = NSAttributedString(string: route, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color.darkText ? NSColor.black : NSColor.white,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
    }
}
