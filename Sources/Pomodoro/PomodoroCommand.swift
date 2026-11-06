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
    /// (`/pomo 500`), which the launcher beeps at.
    static func preview(
        of command: PomodoroCommand?, state: PomodoroState, completedFocusSessions: Int
    ) -> Preview {
        guard let command else {
            return Preview(text: "Type a number of minutes (1 to \(maxMinutes)), pause, resume, skip or stop", runs: false)
        }
        let current = state.phase.map(\.noun)
        switch command {
        case .toggle:
            switch state {
            case .idle: return Preview(text: "Start a \(minutes(nil)) min focus session", runs: true)
            case .running: return Preview(text: "Pause the \(current ?? "")", runs: true)
            case .paused: return Preview(text: "Resume the \(current ?? "")", runs: true)
            }
        case .start(let length):
            guard let current else { return Preview(text: "Start a \(minutes(length)) min focus session", runs: true) }
            return Preview(text: "Replace the \(current) with a \(minutes(length)) min focus session", runs: true)
        case .pause:
            switch state {
            case .idle: return Preview(text: "Nothing to pause", runs: false)
            case .running: return Preview(text: "Pause the \(current ?? "")", runs: true)
            case .paused: return Preview(text: "Already paused", runs: false)
            }
        case .resume:
            switch state {
            case .idle: return Preview(text: "Nothing to resume", runs: false)
            case .running: return Preview(text: "Already running", runs: false)
            case .paused: return Preview(text: "Resume the \(current ?? "")", runs: true)
            }
        case .skip:
            switch state.phase {
            case nil: return Preview(text: "Nothing to skip", runs: false)
            case .focus?: return Preview(text: "Skip to the break", runs: true)
            case let phase?: return Preview(text: "End the \(phase.noun)", runs: true)
            }
        case .stop:
            guard let current else {
                return completedFocusSessions > 0
                    ? Preview(text: "Reset the cycle", runs: true)
                    : Preview(text: "Nothing to stop", runs: false)
            }
            return Preview(text: "Stop the \(current) and reset the cycle", runs: true)
        }
    }

    /// The length `start(minutes:)` gives a focus session, in whole minutes.
    static func minutes(_ length: Int?) -> Int {
        length ?? Int((Config.pomodoroFocus / 60).rounded())
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
