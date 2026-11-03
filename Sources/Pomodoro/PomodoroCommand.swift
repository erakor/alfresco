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
