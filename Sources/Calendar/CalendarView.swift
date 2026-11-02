// CalendarView.swift
//
// The calendar area under the launcher field. `cal` shows "next up first":
// a line for the event under way, a card for the next one with a countdown,
// then two columns with the rest of today and the next day that has events.
// `cal <text>` lists the matches under day headers, each row with its
// calendar's color, its time, its title, and "en cours" / "dans 12 min" or
// its place. The height follows the content (preferredHeight). Labels are in
// French, like the weather.

import Cocoa

final class CalendarView: NSView {
    private static let headerHeight: CGFloat = 24
    private static let rowHeight: CGFloat = 26
    private static let moreHeight: CGFloat = 22
    private static let statusHeight: CGFloat = 52
    private static let padding: CGFloat = 8
    // "Next up first" (`cal`)
    private static let ongoingHeight: CGFloat = 18
    private static let cardHeight: CGFloat = 72
    private static let columnHeaderHeight: CGFloat = 22
    private static let compactRowHeight: CGFloat = 24
    private static let sectionGap: CGFloat = 12
    /// Rows in each of the two columns under the card.
    private static let rowsPerColumn = 4

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

    /// "mer. 4", under the card's clock for an event after tomorrow.
    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.setLocalizedDateFormatFromTemplate("EEEd")
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
        case .loading(let text):
            add(Self.statusRow(symbolName: nil, text: text), height: Self.statusHeight)
        case .message(let text):
            add(Self.statusRow(symbolName: "exclamationmark.triangle", text: text), height: Self.statusHeight)
        case .loaded(let events, let hiddenCount):
            guard !events.isEmpty else {
                add(Self.statusRow(symbolName: "calendar", text: Self.emptyText(for: query)), height: Self.statusHeight)
                break
            }
            let now = Date()
            if query == .upcoming {
                for (view, height) in Self.nextUpSections(events, now: now) {
                    add(view, height: height)
                }
                break
            }
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
                add(Self.moreLabel(hiddenCount), height: Self.moreHeight)
            }
        }
        // The separator plus a little slack for its own height.
        preferredHeight = contentHeight + 2 * Self.padding + 4
    }

    // MARK: Formatting

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    static func shortDay(_ date: Date) -> String {
        shortDayFormatter.string(from: date)
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

    /// "Aujourd'hui", "Demain", else "Mercredi 4 novembre".
    static func dayTitle(_ day: Date, today: Date) -> String {
        if day == today { return "Aujourd'hui" }
        if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today), day == tomorrow {
            return "Demain"
        }
        let name = dayFormatter.string(from: day)
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func header(for day: Date, today: Date) -> NSView {
        header(dayTitle(day, today: today))
    }

    /// "+ 3 autres événements", for what didn't fit.
    private static func moreLabel(_ count: Int) -> NSTextField {
        let text = count == 1 ? "+ 1 autre événement" : "+ \(count) autres événements"
        return label(text, size: 11, color: .tertiaryLabelColor)
    }

    /// Title, calendar and place, one per line, for hovering an event.
    static func tooltip(for event: CalendarEvent) -> String {
        [event.title, event.calendarName, event.location ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Next up first

    /// The `cal` layout, as stacked sections with their heights: the events
    /// under way, the next timed event's card, two columns (the rest of
    /// today, and the next day with events), and how many are left out.
    private static func nextUpSections(_ events: [CalendarEvent], now: Date) -> [(NSView, CGFloat)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func day(of event: CalendarEvent) -> Date { max(calendar.startOfDay(for: event.start), today) }

        let ongoing = events.indices.filter { !events[$0].isAllDay && events[$0].start <= now && now < events[$0].end }
        let next = events.indices.first { !events[$0].isAllDay && events[$0].start > now }
        var used = Set(ongoing)
        if let next { used.insert(next) }
        let rest = events.indices.filter { !used.contains($0) }
        let laterToday = rest.filter { day(of: events[$0]) == today }
        let later = rest.filter { day(of: events[$0]) > today }
        let nextDay = later.first.map { day(of: events[$0]) }
        let nextDayEvents = later.filter { day(of: events[$0]) == nextDay }

        var sections: [(NSView, CGFloat)] = []
        if let first = ongoing.first {
            sections.append((ongoingLine(events[first], others: ongoing.count - 1, now: now), ongoingHeight))
        }
        if let next {
            sections.append((NextCard(event: events[next], now: now, today: today), cardHeight))
        }
        let leftShown = Array(laterToday.prefix(rowsPerColumn))
        let rightShown = Array(nextDayEvents.prefix(rowsPerColumn))
        if !leftShown.isEmpty || !rightShown.isEmpty {
            let left = column(
                title: "Plus tard aujourd'hui", events: leftShown.map { events[$0] },
                day: today, emptyText: "Rien d'autre aujourd'hui"
            )
            let right = column(
                title: nextDay.map { dayTitle($0, today: today) } ?? "Ensuite",
                events: rightShown.map { events[$0] },
                day: nextDay ?? today, emptyText: "Rien de prévu ensuite"
            )
            let columns = NSStackView(views: [left, right])
            columns.orientation = .horizontal
            columns.distribution = .fillEqually
            columns.alignment = .top
            columns.spacing = 24
            let rows = max(leftShown.count, rightShown.count, 1)
            sections.append((columns, columnHeaderHeight + CGFloat(rows) * compactRowHeight))
        }
        let hidden = events.count - used.count - leftShown.count - rightShown.count
        if hidden > 0 {
            sections.append((moreLabel(hidden), moreHeight))
        }

        // A gap between sections, with its height, so preferredHeight adds up.
        var spaced: [(NSView, CGFloat)] = []
        for (index, section) in sections.enumerated() {
            if index > 0 { spaced.append((NSView(), sectionGap)) }
            spaced.append(section)
        }
        return spaced
    }

    /// "En cours : Standup, se termine dans 10 min" (or "à 11:30" past the
    /// hour), plus how many others are under way.
    private static func ongoingLine(_ event: CalendarEvent, others: Int, now: Date) -> NSView {
        let minutes = Int((event.end.timeIntervalSince(now) / 60).rounded(.up))
        let ends = minutes < 60 ? "se termine dans \(max(1, minutes)) min" : "se termine à \(clock(event.end))"
        var text = " : \(event.title), \(ends)"
        if others > 0 { text += others == 1 ? " (+ 1 autre)" : " (+ \(others) autres)" }

        let dot = colorDot(event.color)
        let tag = label("En cours", size: 12, color: .systemGreen, weight: .semibold)
        tag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let rest = label(text, size: 12, color: .secondaryLabelColor)
        let row = NSStackView(views: [dot, tag, rest])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.setCustomSpacing(8, after: dot)
        return row
    }

    /// A header and up to rowsPerColumn compact rows, or one line saying
    /// there is nothing.
    private static func column(title: String, events: [CalendarEvent], day: Date, emptyText: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        var views: [(NSView, CGFloat)] = [(header(title), columnHeaderHeight)]
        if events.isEmpty {
            views.append((label(emptyText, size: 12, color: .tertiaryLabelColor), compactRowHeight))
        } else {
            views += events.map { event -> (NSView, CGFloat) in (CompactRow(event: event, day: day), compactRowHeight) }
        }
        for (view, height) in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.heightAnchor.constraint(equalToConstant: height),
                view.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
        return stack
    }

    private static func header(_ text: String) -> NSView {
        let container = NSView()
        let title = label(text, size: 11, color: .secondaryLabelColor, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            title.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    static func colorDot(_ color: NSColor) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        return dot
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

        let dot = CalendarView.colorDot(event.color)

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

        toolTip = CalendarView.tooltip(for: event)

        for view in [dot, time, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),

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

/// The next timed event: a countdown on the left ("10 min", or its time and
/// day), then "PROCHAIN", its title, and its time, place and calendar, on a
/// tint of its calendar's color.
private final class NextCard: NSView {
    init(event: CalendarEvent, now: Date, today: Date) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = event.color.withAlphaComponent(0.16).cgColor
        layer?.cornerRadius = 10

        let calendar = Calendar.current
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        let big: String
        let unit: String
        if minutes < 60 {
            big = "\(max(1, minutes))"
            unit = "min"
        } else {
            big = CalendarView.clock(event.start)
            let day = calendar.startOfDay(for: event.start)
            if day == today {
                unit = "aujourd'hui"
            } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), day == tomorrow {
                unit = "demain"
            } else {
                unit = CalendarView.shortDay(event.start)
            }
        }
        let bigLabel = NSTextField(labelWithString: big)
        bigLabel.font = .monospacedDigitSystemFont(ofSize: minutes < 60 ? 26 : 20, weight: .semibold)
        bigLabel.textColor = .labelColor
        bigLabel.alignment = .center
        let unitLabel = CalendarView.label(unit, size: 11, color: .secondaryLabelColor)
        unitLabel.alignment = .center
        let countdown = NSStackView(views: [bigLabel, unitLabel])
        countdown.orientation = .vertical
        countdown.alignment = .centerX
        countdown.spacing = 0

        let tag = CalendarView.label("PROCHAIN", size: 10, color: .secondaryLabelColor, weight: .semibold)
        let title = CalendarView.label(event.title, size: 17, color: .labelColor, weight: .semibold)
        let details = [
            "\(CalendarView.clock(event.start)) – \(CalendarView.clock(event.end))",
            event.location ?? "",
            event.calendarName,
        ].filter { !$0.isEmpty }.joined(separator: " · ")
        let detailLabel = CalendarView.label(details, size: 12, color: .secondaryLabelColor)
        let texts = NSStackView(views: [tag, title, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        toolTip = CalendarView.tooltip(for: event)

        for view in [countdown, texts] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            countdown.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            countdown.centerYAnchor.constraint(equalTo: centerYAnchor),
            countdown.widthAnchor.constraint(equalToConstant: 76),

            texts.leadingAnchor.constraint(equalTo: countdown.trailingAnchor, constant: 12),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// One event in a column under the card: color dot, start time ("Journée"
/// for all day), then the title and place.
private final class CompactRow: NSView {
    init(event: CalendarEvent, day: Date) {
        super.init(frame: .zero)
        let dot = CalendarView.colorDot(event.color)
        let timeText: String
        if event.isAllDay {
            timeText = "Journée"
        } else if Calendar.current.isDate(event.start, inSameDayAs: day) {
            timeText = CalendarView.clock(event.start)
        } else {
            timeText = "…"
        }
        let time = NSTextField(labelWithString: timeText)
        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        time.textColor = .secondaryLabelColor
        let name = [event.title, event.location ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let title = CalendarView.label(name, size: 12, color: .labelColor)
        toolTip = CalendarView.tooltip(for: event)

        for view in [time, title] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(dot)
        addSubview(time)
        addSubview(title)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),

            time.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
            time.widthAnchor.constraint(equalToConstant: 52),

            title.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
