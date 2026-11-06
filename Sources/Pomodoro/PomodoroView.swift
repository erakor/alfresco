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
        /// Idle or paused: grey, with the clock dimmed.
        case neutral, focus, rest
    }

    var symbolName: String
    var tint: Tint
    /// m:ss: the time left, or the length Enter would start while idle.
    var clock: String
    /// "FOCUS 2 OF 4", "SHORT BREAK", "LONG BREAK".
    var tag: String
    /// "Ends at 14:32", "Paused", "Not started".
    var title: String
    /// "Then a 5 min break", "Then focus 3 of 4", "Cycle complete, then a new one".
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
        // While idle, the count the next session starts from.
        let counted = state == .idle ? PomodoroTimer.cycleCountAtStart(completedFocusSessions) : completedFocusSessions
        let done = min(max(0, counted), total)
        let session = min(done + 1, total)

        symbolName = (state.phase ?? .focus).symbolName
        clock = PomodoroTimer.format(state == .idle ? TimeInterval(startMinutes * 60) : remaining ?? 0)
        switch state.phase {
        case nil, .focus?:
            tag = "\(PomodoroPhase.focus.name) \(session) of \(total)".uppercased()
            detail = session >= total
                ? "Then a \(PomodoroPhase.longBreak.minutes) min long break"
                : "Then a \(PomodoroPhase.shortBreak.minutes) min break"
        case .shortBreak?:
            tag = PomodoroPhase.shortBreak.name.uppercased()
            detail = "Then focus \(session) of \(total)"
        case .longBreak?:
            tag = PomodoroPhase.longBreak.name.uppercased()
            detail = "Cycle complete, then a new one"
        }
        switch state {
        case .idle:
            tint = .neutral
            title = "Not started"
        case .running(let phase, _):
            tint = phase.isBreak ? .rest : .focus
            title = endTime.map { "Ends at \($0)" } ?? ""
        case .paused:
            tint = .neutral
            title = "Paused"
        }

        cycle = String(repeating: "●", count: done) + String(repeating: "○", count: total - done)
        cycleToolTip = "\(done) of \(total) focus sessions before the long break"
        switch sessionsToday {
        case ...0: today = "No focus session finished today"
        case 1: today = "1 focus session today"
        default: today = "\(sessionsToday) focus sessions today"
        }
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
    private let tagLabel = NSTextField.areaLabel(size: 10, color: .secondaryLabelColor, weight: .semibold)
    private let titleLabel = NSTextField.areaLabel(size: 17, color: .labelColor, weight: .semibold)
    private let detailLabel = NSTextField.areaLabel(size: 12, color: .secondaryLabelColor)
    private let cycleLabel = NSTextField.areaLabel(size: 12, color: .secondaryLabelColor)
    private let todayLabel = NSTextField.areaLabel(size: 12, color: .secondaryLabelColor)
    private var shown: PomodoroViewContent?

    private static let endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        // Follow a time zone change while the app runs, like the timer's day.
        formatter.timeZone = .autoupdatingCurrent
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
        var endTime: String?
        if case .running(_, let endsAt) = timer.state { endTime = Self.endTimeFormatter.string(from: endsAt) }
        let content = PomodoroViewContent(
            state: timer.state, remaining: timer.remaining(),
            completedFocusSessions: timer.completedFocusSessions, sessionsToday: timer.focusSessionsToday,
            startMinutes: startMinutes, endTime: endTime
        )
        guard content != shown else { return }
        if content.symbolName != shown?.symbolName {
            icon.image = NSImage(systemSymbolName: content.symbolName, accessibilityDescription: nil)
        }
        if content.tint != shown?.tint {
            applyTint(content.tint)
        }
        shown = content
        // Every second while running, and most ticks only change the clock:
        // setting a label's text lays it out again, even to the same text.
        for (label, text) in [
            (clockLabel, content.clock), (tagLabel, content.tag), (titleLabel, content.title),
            (detailLabel, content.detail), (cycleLabel, content.cycle), (todayLabel, content.today),
        ] where label.stringValue != text {
            label.stringValue = text
        }
        cycleLabel.toolTip = content.cycleToolTip
    }

    /// The card's color: red for focus, green for a break, neutral while
    /// idle or paused, when the clock is dimmed too.
    private func applyTint(_ tint: PomodoroViewContent.Tint) {
        let color: NSColor
        switch tint {
        case .neutral: color = .secondaryLabelColor
        case .focus: color = .systemRed
        case .rest: color = .systemGreen
        }
        let muted = tint == .neutral
        card.layer?.backgroundColor = color.withAlphaComponent(muted ? 0.1 : 0.16).cgColor
        icon.contentTintColor = color
        clockLabel.textColor = muted ? .secondaryLabelColor : .labelColor
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
