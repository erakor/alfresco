// PomodoroCommand.swift
//
// What an alfresco://pomodoro/... URL from workflows.json asks the timer to
// do. The launcher hands these URLs to the app instead of opening them.

import Foundation

enum PomodoroCommand: Equatable, Sendable {
    /// Starts a focus session when idle, otherwise pauses or resumes.
    case toggle
    /// A new focus session, of Config.pomodoroFocus when minutes is nil.
    case start(minutes: Int?)
    case pause
    case resume
    case skip
    case stop

    /// The host of its alfresco:// URLs.
    static let feature = "pomodoro"

    /// Longest focus session `/pomo <minutes>` accepts.
    static let maxMinutes = 180

    /// alfresco://pomodoro/<action>, where <action> is toggle, start, pause,
    /// resume, skip, stop, or a number of minutes (1 to maxMinutes). nil for
    /// anything else, so the launcher can beep.
    init?(url: URL) {
        guard let action = InternalURL.action(of: url, feature: Self.feature) else { return nil }
        switch action {
        case "toggle", "": self = .toggle
        case "start": self = .start(minutes: nil)
        case "pause": self = .pause
        case "resume": self = .resume
        case "skip": self = .skip
        case "stop": self = .stop
        default:
            guard action.allSatisfy({ $0.isASCII && $0.isNumber }), let minutes = Int(action),
                  (1...Self.maxMinutes).contains(minutes) else { return nil }
            self = .start(minutes: minutes)
        }
    }
}

// MARK: - What Enter would do

extension PomodoroCommand {
    /// What running a command would do right now, for the launcher's hint
    /// under `/pomo`: `runs` is false when the timer would refuse it (Enter
    /// beeps), and `text` then says why.
    struct Preview: Equatable, Sendable {
        let text: String
        let runs: Bool

        /// "↩ Pause the focus session", or the reason alone ("Nothing to pause").
        var hint: String { runs ? "↩ \(text)" : text }
    }

    /// `command` is nil for an action PomodoroCommand doesn't know
    /// (`/pomo 500`), which the launcher beeps at. `runs` follows
    /// PomodoroTimer.run's guards. `now` tells a phase that has run out
    /// but not ticked yet, which pausing ends instead (PomodoroTimer.pause).
    static func preview(
        of command: PomodoroCommand?, state: PomodoroState, completedFocusSessions: Int, now: Date
    ) -> Preview {
        guard let command else {
            return Preview(text: "Type a number of minutes (1 to \(maxMinutes)), pause, resume, skip or stop", runs: false)
        }
        if case .running(let phase, let endsAt) = state, endsAt <= now, command == .toggle || command == .pause {
            return Preview(text: "End the \(phase.noun)", runs: true)
        }
        switch (command, state) {
        case (.toggle, .idle), (.start, .idle):
            return Preview(text: "Start a \(command.startMinutes) min focus session", runs: true)
        case (.toggle, .running(let phase, _)), (.pause, .running(let phase, _)):
            return Preview(text: "Pause the \(phase.noun)", runs: true)
        case (.toggle, .paused(let phase, _)), (.resume, .paused(let phase, _)):
            return Preview(text: "Resume the \(phase.noun)", runs: true)
        case (.start, .running(let phase, _)), (.start, .paused(let phase, _)):
            return Preview(text: "Replace the \(phase.noun) with a \(command.startMinutes) min focus session", runs: true)
        case (.pause, .idle): return Preview(text: "Nothing to pause", runs: false)
        case (.pause, .paused): return Preview(text: "Already paused", runs: false)
        case (.resume, .idle): return Preview(text: "Nothing to resume", runs: false)
        case (.resume, .running): return Preview(text: "Already running", runs: false)
        case (.skip, .idle): return Preview(text: "Nothing to skip", runs: false)
        case (.skip, .running(.focus, _)), (.skip, .paused(.focus, _)):
            return Preview(text: "Skip to the break", runs: true)
        case (.skip, .running(let phase, _)), (.skip, .paused(let phase, _)):
            return Preview(text: "End the \(phase.noun)", runs: true)
        case (.stop, .idle):
            return completedFocusSessions > 0
                ? Preview(text: "Reset the cycle", runs: true)
                : Preview(text: "Nothing to stop", runs: false)
        case (.stop, .running(let phase, _)), (.stop, .paused(let phase, _)):
            return Preview(text: "Stop the \(phase.noun) and reset the cycle", runs: true)
        }
    }

    /// The focus length, in minutes, a session started by this command
    /// gets: the typed one, else Config.pomodoroFocus.
    var startMinutes: Int {
        if case .start(let minutes?) = self { return minutes }
        return PomodoroPhase.focus.minutes
    }
}

extension PomodoroPhase {
    /// "focus session", "short break", "long break", for sentences.
    var noun: String {
        switch self {
        case .focus: return "focus session"
        case .shortBreak: return "short break"
        case .longBreak: return "long break"
        }
    }
}
