// PomodoroView.swift
//
// The pomodoro area under the launcher input, shown while the input runs an
// alfresco://pomodoro/... workflow (`/pomo`, `/pomo 50`): a card with the
// phase, the time left and what comes next, then the cycle and today's
// finished focus sessions. What Enter would do is in the launcher's hint
// (PomodoroCommand.preview). The launcher refreshes it on every timer
// change and tick while it is shown.

import Cocoa

/// What the view shows, worked out without AppKit so the self-test can
/// check it.
struct PomodoroViewContent: Equatable {
    enum Tint: Equatable {
        case idle, focus, rest, paused
    }

    var symbolName: String
    var tint: Tint
    /// m:ss: the time left, or the length Enter would start while idle.
    var clock: String
    /// "FOCUS 2 OF 4", "SHORT BREAK", "LONG BREAK".
    var tag: String
    /// "Ends at 14:32", "Paused", "Not started".
    var title: String
    /// "Then a 5 min break", "Then focus 3 of 4", "Then a new cycle".
    var detail: String
    /// "●●○○": focus sessions done in this cycle.
    var cycle: String
    var cycleToolTip: String
    /// "3 focus sessions today".
    var today: String

    /// `startMinutes` is the length an idle timer would start (`/pomo 50`
    /// shows 50:00). `endTime` is the end date as shown, while running.
    init(
        state: PomodoroState, remaining: TimeInterval?, completedFocusSessions: Int, sessionsToday: Int,
        startMinutes: Int, endTime: String?
    ) {
        let total = Config.pomodoroSessionsBeforeLongBreak
        let done = min(max(0, completedFocusSessions), total)
        // startFocus starts a new cycle once the long break was due.
        let nextFocus = completedFocusSessions >= total ? 1 : done + 1

        switch state.phase {
        case nil:
            symbolName = "timer"
            tint = .idle
            clock = PomodoroTimer.format(TimeInterval(startMinutes) * 60)
            tag = "FOCUS \(nextFocus) OF \(total)"
            title = "Not started"
            detail = PomodoroViewContent.afterFocus(number: nextFocus, of: total)
        case .focus?:
            symbolName = "timer"
            tint = .focus
            clock = PomodoroTimer.format(remaining ?? 0)
            tag = "FOCUS \(min(done + 1, total)) OF \(total)"
            title = ""
            detail = PomodoroViewContent.afterFocus(number: done + 1, of: total)
        case .shortBreak?:
            symbolName = "cup.and.saucer"
            tint = .rest
            clock = PomodoroTimer.format(remaining ?? 0)
            tag = "SHORT BREAK"
            title = ""
            detail = "Then focus \(min(done + 1, total)) of \(total)"
        case .longBreak?:
            symbolName = "cup.and.saucer"
            tint = .rest
            clock = PomodoroTimer.format(remaining ?? 0)
            tag = "LONG BREAK"
            title = ""
            detail = "Cycle complete, then a new one"
        }
        switch state {
        case .idle:
            break
        case .running:
            title = endTime.map { "Ends at \($0)" } ?? ""
        case .paused:
            title = "Paused"
            tint = .paused
        }

        cycle = String(repeating: "●", count: done) + String(repeating: "○", count: total - done)
        cycleToolTip = "\(done) of \(total) focus sessions before the long break"
        switch sessionsToday {
        case ...0: today = "No focus session finished today"
        case 1: today = "1 focus session today"
        default: today = "\(sessionsToday) focus sessions today"
        }
    }

    /// What follows focus session `number`: the long break after the last
    /// one of the cycle, else a short one.
    private static func afterFocus(number: Int, of total: Int) -> String {
        number >= total
            ? "Then a \(minutes(Config.pomodoroLongBreak)) min long break"
            : "Then a \(minutes(Config.pomodoroShortBreak)) min break"
    }

    private static func minutes(_ duration: TimeInterval) -> Int {
        Int((duration / 60).rounded())
    }
}

final class PomodoroView: NSView {
    /// Height the launcher adds below its input row.
    static let height: CGFloat = 124
    private static let padding: CGFloat = 8
    private static let cardHeight: CGFloat = 72

    private let separator = NSBox()
    private let card = NSView()
    private let icon = NSImageView()
    private let clockLabel = NSTextField(labelWithString: "")
    private let tagLabel = PomodoroView.label(size: 10, color: .secondaryLabelColor, weight: .semibold)
    private let titleLabel = PomodoroView.label(size: 17, color: .labelColor, weight: .semibold)
    private let detailLabel = PomodoroView.label(size: 12, color: .secondaryLabelColor)
    private let cycleLabel = PomodoroView.label(size: 12, color: .secondaryLabelColor)
    private let todayLabel = PomodoroView.label(size: 12, color: .secondaryLabelColor)
    private var shown: PomodoroViewContent?

    private static let endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows the timer as it is now. `startMinutes` is the length Enter
    /// would start while idle.
    func show(_ timer: PomodoroTimer, startMinutes: Int) {
        let content = PomodoroViewContent(
            state: timer.state, remaining: timer.remaining(),
            completedFocusSessions: timer.completedFocusSessions, sessionsToday: timer.focusSessionsToday,
            startMinutes: startMinutes, endTime: timer.endsAt.map { Self.endTimeFormatter.string(from: $0) }
        )
        // Every second while running; most ticks only change the clock.
        guard content != shown else { return }
        if content.symbolName != shown?.symbolName {
            icon.image = NSImage(systemSymbolName: content.symbolName, accessibilityDescription: nil)
        }
        if content.tint != shown?.tint {
            applyTint(content.tint)
        }
        shown = content
        clockLabel.stringValue = content.clock
        tagLabel.stringValue = content.tag
        titleLabel.stringValue = content.title
        detailLabel.stringValue = content.detail
        cycleLabel.stringValue = content.cycle
        cycleLabel.toolTip = content.cycleToolTip
        todayLabel.stringValue = content.today
    }

    /// The card's color: red for focus, green for a break, neutral while
    /// idle or paused, when the clock is dimmed too.
    private func applyTint(_ tint: PomodoroViewContent.Tint) {
        let color: NSColor
        switch tint {
        case .idle, .paused: color = .secondaryLabelColor
        case .focus: color = .systemRed
        case .rest: color = .systemGreen
        }
        card.layer?.backgroundColor = color.withAlphaComponent(tint == .idle || tint == .paused ? 0.1 : 0.16).cgColor
        icon.contentTintColor = color
        clockLabel.textColor = tint == .idle || tint == .paused ? .secondaryLabelColor : .labelColor
    }

    /// The layer color is resolved when set, so a switch between light and
    /// dark mode sets it again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let tint = shown?.tint {
            effectiveAppearance.performAsCurrentDrawingAppearance { self.applyTint(tint) }
        }
    }

    #if SELFTEST
    /// What the labels read, for the self-test.
    var contentForSelfTest: PomodoroViewContent? { shown }
    #endif

    private static func label(size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func build() {
        separator.boxType = .separator
        card.wantsLayer = true
        card.layer?.cornerRadius = 10

        clockLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        clockLabel.setContentHuggingPriority(.required, for: .horizontal)
        clockLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let texts = NSStackView(views: [tagLabel, titleLabel, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let footer = NSStackView(views: [cycleLabel, todayLabel])
        footer.orientation = .horizontal
        footer.spacing = 10

        for view in [icon, clockLabel, texts] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        for view in [separator, card, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            card.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: Self.padding),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.heightAnchor.constraint(equalToConstant: Self.cardHeight),

            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            // Wide enough for 180:00, so the texts don't move as it counts.
            clockLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            clockLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            clockLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),

            texts.leadingAnchor.constraint(equalTo: clockLabel.trailingAnchor, constant: 12),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
            texts.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            footer.topAnchor.constraint(equalTo: card.bottomAnchor, constant: Self.padding),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            footer.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
}
