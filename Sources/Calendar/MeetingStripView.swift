// MeetingStripView.swift
//
// The next meeting in the launcher's top-left corner, above the input, on
// the weather's line: its calendar's color, its title, and when it starts
// ("dans 12 min" within the hour, else "14:30", "demain 09:00" or
// "mer. 4, 09:00"). Shown while Config.calendarStrip is on and calendar
// access was already granted (it never asks: the prompt would close the
// launcher), and only when a timed event starts within Config.calendarDays.
// Clicking it calls onClick (the launcher types `/cal`).

import Cocoa

/// Which event the strip shows and how it says when, checked by the
/// self-test (main actor only for CalendarView's date formatters).
@MainActor
enum NextMeeting {
    /// Within this many seconds, the start is a countdown.
    static let soonInterval: TimeInterval = 60 * 60

    /// The first timed event still to start, the one `/cal`'s card shows.
    /// `events` are in start order, as CalendarProvider gives them.
    static func find(in events: [CalendarEvent], now: Date) -> CalendarEvent? {
        events.first { !$0.isAllDay && $0.start > now }
    }

    /// Whether `event` starts within the hour.
    static func isSoon(_ event: CalendarEvent, now: Date) -> Bool {
        event.start.timeIntervalSince(now) < soonInterval
    }

    /// "dans 12 min" within the hour, else "14:30" today, "demain 09:00",
    /// or "mer. 4, 09:00" further on.
    static func whenText(for event: CalendarEvent, now: Date) -> String {
        if isSoon(event, now: now) {
            let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
            return "dans \(max(1, minutes)) min"
        }
        let calendar = Calendar.current
        let clock = CalendarView.clock(event.start)
        let today = calendar.startOfDay(for: now)
        switch DateMath.days(from: today, to: calendar.startOfDay(for: event.start), calendar: calendar) {
        case 0: return clock
        case 1: return "demain \(clock)"
        default: return "\(CalendarView.shortDay(event.start)), \(clock)"
        }
    }
}

final class MeetingStripView: NSView {
    /// The meeting was clicked (on mouse up, inside it).
    var onClick: (() -> Void)? {
        get { button.onClick }
        set { button.onClick = newValue }
    }

    /// The whole view is the button: it is as wide as the meeting.
    private let button = StripButton()
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let whenLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ event: CalendarEvent, now: Date) {
        dot.layer?.backgroundColor = event.color.cgColor
        titleLabel.stringValue = event.title
        let when = NextMeeting.whenText(for: event, now: now)
        whenLabel.stringValue = when
        button.setAccessibilityLabel("Prochain rendez-vous : \(event.title), \(when)")
        if NextMeeting.isSoon(event, now: now) {
            whenLabel.textColor = .systemOrange
            whenLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        } else {
            whenLabel.textColor = .tertiaryLabelColor
            whenLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        button.toolTip = CalendarView.tooltip(for: event) + "\n" + CalendarView.cardTimeText(for: event)
            + "\nCliquez ou tapez \(CommandInput.typed(Config.calendarKeyword)) pour l'agenda"
    }

    private func build() {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        // Truncated before the weather's text when the line is full.
        titleLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(240), for: .horizontal)
        whenLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        whenLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let group = NSStackView(views: [dot, titleLabel, whenLabel])
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 6
        group.setCustomSpacing(8, after: titleLabel)
        button.install(group, in: self)

        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp("Affiche l'agenda")
    }

    /// Forgets a hover or press, for when the panel closes: no exit event
    /// comes with it.
    func clearHover() { button.clearHover() }

    #if SELFTEST
    /// What the strip reads: the title, then when.
    var textForSelfTest: String { "\(titleLabel.stringValue) \(whenLabel.stringValue)" }

    /// Clicks the meeting as the mouse would.
    func clickForSelfTest() { _ = button.accessibilityPerformPress() }
    #endif
}
