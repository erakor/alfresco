// PomodoroAlert.swift
//
// What happens when a pomodoro phase runs out: a sound every time, and a
// macOS notification when the app runs as a bundle (build/Launcher.app).

import AppKit
import UserNotifications

/// Where an alert's sound and notification go. The app uses
/// SystemPomodoroAlertSink; the self-test records them instead.
@MainActor
protocol PomodoroAlertSink: AnyObject {
    func playSound(named name: String)
    func notify(title: String, body: String)
}

/// NSSound and UNUserNotificationCenter.
@MainActor
final class SystemPomodoroAlertSink: PomodoroAlertSink {
    func playSound(named name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    func notify(title: String, body: String) {
        PomodoroAlert.post(title: title, body: body)
    }
}

enum PomodoroAlert {
    @MainActor private static var didRequestPermission = false
    @MainActor static var sink: PomodoroAlertSink = SystemPomodoroAlertSink()

    /// UNUserNotificationCenter needs an app bundle; in a plain binary built
    /// with swiftc it raises an exception, so notifications are skipped there.
    static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asks once per launch for permission to post notifications (macOS only
    /// shows the prompt the first time). Called when a session starts, so the
    /// prompt comes up when you start a timer rather than at launch.
    @MainActor
    static func requestPermission() {
        guard notificationsAvailable, !didRequestPermission else { return }
        didRequestPermission = true
        // Kept out of main-actor code: the completion handler runs on a
        // background queue.
        requestAuthorization()
    }

    /// `phase` just ran out; `next` is the timer's state now.
    @MainActor
    static func play(ended phase: PomodoroPhase, next: PomodoroState) {
        sink.playSound(named: Config.pomodoroSound)
        guard notificationsAvailable else { return }
        let text = message(ended: phase, next: next)
        sink.notify(title: text.title, body: text.body)
    }

    static func message(ended phase: PomodoroPhase, next: PomodoroState) -> (title: String, body: String) {
        switch phase {
        case .focus:
            guard let breakPhase = next.phase else { return ("Focus session done", "") }
            let minutes = Int((breakPhase.duration / 60).rounded())
            let kind = breakPhase == .longBreak ? "long break" : "break"
            if next.isPaused {
                return ("Focus session done", "Your \(minutes) min \(kind) is waiting in the menu bar.")
            }
            return ("Focus session done", "Time for a \(minutes) min \(kind).")
        case .shortBreak:
            return ("Break over", "Ready for the next focus session.")
        case .longBreak:
            return ("Long break over", "Cycle complete. Start a new one when you're ready.")
        }
    }

    private static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, error in
            if let error { NSLog("Launcher: pomodoro notifications are unavailable: \(error)") }
        }
    }

    /// The sound is played separately, so the notification has none. One
    /// identifier, so a new notification replaces the previous one.
    fileprivate static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "pomodoro", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Launcher: could not post the pomodoro notification: \(error)") }
        }
    }
}

extension PomodoroTimer {
    /// The app's wiring: the menu bar item follows every change, and a phase
    /// that runs out by itself plays the alert.
    func connect(to statusItem: PomodoroStatusItem) {
        onChange = { [weak statusItem] in statusItem?.update() }
        onPhaseEnd = { [weak self] phase in
            guard let self else { return }
            PomodoroAlert.play(ended: phase, next: self.state)
        }
    }
}
