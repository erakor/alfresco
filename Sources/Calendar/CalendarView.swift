// CalendarView.swift
//
// The event list under the launcher field while the input is `cal` or
// `cal <text>`: events grouped under day headers, each with its calendar's
// color, its time, its title, and "en cours" / "dans 12 min" or its place.
// Its height follows the content (preferredHeight). Labels are in French, like
// the weather.

import Cocoa

final class CalendarView: NSView {
    private static let headerHeight: CGFloat = 24
    private static let rowHeight: CGFloat = 26
    private static let moreHeight: CGFloat = 22
    private static let statusHeight: CGFloat = 52
    private static let padding: CGFloat = 8

    private let separator = NSBox()
    private let stack = NSStackView()

    /// Height the launcher adds below its input row for the current content.
    private(set) var preferredHeight: CGFloat = 0

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ state: CalendarState, for query: CalendarQuery) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var contentHeight: CGFloat = 0
        func add(_ view: NSView, height: CGFloat) {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.heightAnchor.constraint(equalToConstant: height),
                view.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            contentHeight += height
        }

        switch state {
        case .loading:
            add(Self.statusRow(symbolName: nil, text: "Accès à l'agenda…"), height: Self.statusHeight)
        case .message(let text):
            add(Self.statusRow(symbolName: "exclamationmark.triangle", text: text), height: Self.statusHeight)
        case .loaded(let events, let hiddenCount):
            guard !events.isEmpty else {
                add(Self.statusRow(symbolName: "calendar", text: Self.emptyText(for: query)), height: Self.statusHeight)
                break
            }
            let now = Date()
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            var lastDay: Date?
            for event in events {
                // An event that started before today is listed under today.
                let day = max(calendar.startOfDay(for: event.start), today)
                if day != lastDay {
                    add(Self.header(for: day, today: today), height: Self.headerHeight)
                    lastDay = day
                }
                add(EventRow(event: event, day: day, now: now), height: Self.rowHeight)
            }
            if hiddenCount > 0 {
                let more = hiddenCount == 1 ? "+ 1 autre événement" : "+ \(hiddenCount) autres événements"
                add(Self.label(more, size: 11, color: .tertiaryLabelColor), height: Self.moreHeight)
            }
        }
        // The separator plus a little slack for its own height.
        preferredHeight = contentHeight + 2 * Self.padding + 4
    }

    // MARK: Formatting

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// "09:30 – 10:00", "Toute la journée", or "… – 18:00" for an event
    /// that started on an earlier day.
    static func timeText(for event: CalendarEvent, on day: Date) -> String {
        if event.isAllDay { return "Toute la journée" }
        let calendar = Calendar.current
        let start = calendar.isDate(event.start, inSameDayAs: day) ? clock(event.start) : "…"
        let end = calendar.isDate(event.end, inSameDayAs: day) ? clock(event.end) : "…"
        return "\(start) – \(end)"
    }

    private static func header(for day: Date, today: Date) -> NSView {
        let calendar = Calendar.current
        let text: String
        if day == today {
            text = "Aujourd'hui"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), day == tomorrow {
            text = "Demain"
        } else {
            let name = dayFormatter.string(from: day)
            text = name.prefix(1).uppercased() + name.dropFirst()
        }
        let container = NSView()
        let title = Self.label(text, size: 11, color: .secondaryLabelColor, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    private static func emptyText(for query: CalendarQuery) -> String {
        switch query {
        case .upcoming:
            return Config.calendarDays == 1
                ? "Plus rien de prévu aujourd'hui"
                : "Rien de prévu dans les \(Config.calendarDays) prochains jours"
        case .search:
            return "Aucun événement trouvé dans les \(Config.calendarSearchDays) prochains jours"
        }
    }

    private static func statusRow(symbolName: String?, text: String) -> NSView {
        let leading: NSView
        if let symbolName {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            leading = icon
        } else {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            leading = spinner
        }
        let message = Self.label(text, size: 13, color: .secondaryLabelColor)
        message.toolTip = text
        let row = NSStackView(views: [leading, message])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    static func label(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    // MARK: Setup

    private func build() {
        separator.boxType = .separator
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0

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
        ])
    }
}

/// One event on one line: color dot, time, title, then "en cours",
/// "dans 12 min" or the place on the right.
private final class EventRow: NSView {
    /// "dans N min" is shown for events starting within this many seconds.
    private static let soonInterval: TimeInterval = 60 * 60

    init(event: CalendarEvent, day: Date, now: Date) {
        super.init(frame: .zero)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = event.color.cgColor
        dot.layer?.cornerRadius = 4

        let time = NSTextField(labelWithString: CalendarView.timeText(for: event, on: day))
        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        time.textColor = .secondaryLabelColor

        let title = CalendarView.label(event.title, size: 13, color: .labelColor)
        title.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(249), for: .horizontal)

        let detail: NSTextField
        if !event.isAllDay, event.start <= now, now < event.end {
            detail = CalendarView.label("en cours", size: 11, color: .systemGreen, weight: .medium)
        } else if !event.isAllDay, event.start > now, event.start.timeIntervalSince(now) < Self.soonInterval {
            let minutes = max(1, Int((event.start.timeIntervalSince(now) / 60).rounded(.up)))
            detail = CalendarView.label("dans \(minutes) min", size: 11, color: .systemOrange, weight: .medium)
        } else {
            detail = CalendarView.label(event.location ?? "", size: 11, color: .tertiaryLabelColor)
        }
        detail.alignment = .right

        toolTip = [event.title, event.calendarName, event.location ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        for view in [dot, time, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            time.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
            time.widthAnchor.constraint(equalToConstant: 110),

            title.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
