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
    /// The index of the first timed event still to start, the one `/cal`'s
    /// card shows too. `events` are in start order, as CalendarProvider
    /// gives them.
    static func index(in events: [CalendarEvent], now: Date) -> Int? {
        events.firstIndex { !$0.isAllDay && $0.start > now }
    }

    /// The first timed event still to start.
    static func find(in events: [CalendarEvent], now: Date) -> CalendarEvent? {
        index(in: events, now: now).map { events[$0] }
    }

    /// Whether `event` starts within the hour.
    static func isSoon(_ event: CalendarEvent, now: Date) -> Bool {
        event.start.timeIntervalSince(now) < CalendarView.soonInterval
    }

    /// "dans 12 min" within the hour, else "14:30" today, "demain 09:00",
    /// or "mer. 4, 09:00" further on.
    static func whenText(for event: CalendarEvent, now: Date) -> String {
        if isSoon(event, now: now) {
            return "dans \(CalendarView.minutesUntil(event.start, now: now)) min"
        }
        let calendar = Calendar.current
        let clock = CalendarView.clock(event.start)
        if calendar.isDate(event.start, inSameDayAs: now) { return clock }
        let today = calendar.startOfDay(for: now)
        if let word = CalendarView.relativeWord(calendar.startOfDay(for: event.start), today: today) {
            return "\(word) \(clock)"
        }
        return "\(CalendarView.shortDay(event.start)), \(clock)"
    }
}

final class MeetingStripView: StripView {
    /// Colored in show.
    private let dot = CalendarView.colorDot(.clear)
    private let titleLabel = NSTextField.areaLabel(size: 12, color: .secondaryLabelColor)
    private let whenLabel = NSTextField(labelWithString: "")
    /// The event shown, so the 30 s redraw only touches the tool tip (which
    /// setting dismisses) when it changes; nil while loading.
    private var shownEventKey: String?

    func show(_ event: CalendarEvent, now: Date) {
        let when = NextMeeting.whenText(for: event, now: now)
        whenLabel.stringValue = when
        let soon = NextMeeting.isSoon(event, now: now)
        whenLabel.textColor = soon ? .systemOrange : .tertiaryLabelColor
        whenLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: soon ? .medium : .regular)
        button.setAccessibilityLabel("Prochain rendez-vous : \(event.title), \(when)")

        let key = [
            event.title, "\(event.start.timeIntervalSince1970)", "\(event.end.timeIntervalSince1970)",
            event.location ?? "", event.calendarName,
        ].joined(separator: "\u{1F}")
        guard key != shownEventKey else { return }
        shownEventKey = key
        dot.isHidden = false
        dot.layer?.backgroundColor = event.color.cgColor
        titleLabel.stringValue = event.title
        titleLabel.textColor = .secondaryLabelColor
        button.toolTip = CalendarView.tooltip(for: event) + "\n" + CalendarView.cardTimeText(for: event)
            + "\nCliquez ou tapez \(CommandInput.typed(Config.calendarKeyword)) pour l'agenda"
    }

    /// Before the first events arrive (first opening after launch, or after
    /// midnight).
    func showLoading() {
        shownEventKey = nil
        dot.isHidden = true
        titleLabel.stringValue = "Agenda…"
        titleLabel.textColor = .tertiaryLabelColor
        whenLabel.stringValue = ""
        button.toolTip = nil
        button.setAccessibilityLabel("Prochain rendez-vous : lecture de l'agenda")
    }

    override func build() {
        // Truncated before the weather's text when the line is full.
        titleLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(240), for: .horizontal)
        whenLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let group = NSStackView(views: [dot, titleLabel, whenLabel])
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 6
        group.setCustomSpacing(8, after: titleLabel)
        install(group, help: "Affiche l'agenda")
    }

    #if SELFTEST
    /// What the strip reads: the title, then when.
    var textForSelfTest: String { "\(titleLabel.stringValue) \(whenLabel.stringValue)" }
    #endif
}
