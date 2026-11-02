// PomodoroTimer.swift
//
// The pomodoro state machine: focus sessions, short breaks, a long break
// after every Config.pomodoroSessionsBeforeLongBreak sessions, plus pause,
// resume, skip and stop. Saved on every change, so relaunching or
// rebuilding the app mid-session keeps the countdown.

import AppKit

enum PomodoroPhase: String, Codable, Sendable {
    case focus
    case shortBreak
    case longBreak

    var isBreak: Bool { self != .focus }

    /// Its length from Config. A focus session can be given another one.
    var duration: TimeInterval {
        switch self {
        case .focus: return Config.pomodoroFocus
        case .shortBreak: return Config.pomodoroShortBreak
        case .longBreak: return Config.pomodoroLongBreak
        }
    }

    var name: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }
}

enum PomodoroState: Equatable, Sendable {
    case idle
    case running(PomodoroPhase, endsAt: Date)
    case paused(PomodoroPhase, remaining: TimeInterval)

    var phase: PomodoroPhase? {
        switch self {
        case .idle: return nil
        case .running(let phase, _), .paused(let phase, _): return phase
        }
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

@MainActor
final class PomodoroTimer: NSObject {
    private(set) var state: PomodoroState = .idle
    /// Focus sessions finished since the last long break (or stop).
    private(set) var completedFocusSessions = 0

    /// Called after every change, and every second while running.
    var onChange: (() -> Void)?
    /// Called when a phase runs out by itself (not on skip or stop). `state`
    /// already holds what comes next.
    var onPhaseEnd: ((PomodoroPhase) -> Void)?

    private var ticker: Timer?
    private let fileURL: URL
    /// The current time. Only the self-test passes another clock.
    private let now: @MainActor () -> Date

    /// Saved in ~/Library/Application Support/Launcher, next to the
    /// clipboard history.
    override convenience init() {
        self.init(
            fileURL: ClipboardStore.directory.appendingPathComponent("pomodoro.json"),
            now: { Date() },
            wakeNotifications: NSWorkspace.shared.notificationCenter)
    }

    /// `wakeNotifications` posts NSWorkspace.didWakeNotification. The self-test
    /// gives each timer its own center, so a wake reaches only that timer.
    init(fileURL: URL, now: @escaping @MainActor () -> Date, wakeNotifications: NotificationCenter) {
        self.fileURL = fileURL
        self.now = now
        super.init()
        restore()
        // A Timer doesn't fire while the Mac sleeps; catch up as soon as it
        // wakes rather than on the next tick.
        wakeNotifications.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: Commands

    /// Starts a focus session, replacing whatever runs now. The cycle count
    /// is kept, unless a long break was due or under way.
    func startFocus(minutes: Int? = nil) {
        if completedFocusSessions >= Config.pomodoroSessionsBeforeLongBreak {
            completedFocusSessions = 0
        }
        let duration = minutes.map { TimeInterval($0) * 60 } ?? PomodoroPhase.focus.duration
        transition(to: .running(.focus, endsAt: now().addingTimeInterval(duration)))
    }

    /// Idle: starts a focus session. Running: pauses. Paused: resumes.
    func toggle() {
        switch state {
        case .idle: startFocus()
        case .running: pause()
        case .paused: resume()
        }
    }

    /// A phase whose end has already passed (the Mac just woke, or the tick
    /// hasn't fired yet) finishes instead of being paused with time left.
    @discardableResult
    func pause() -> Bool {
        guard case .running(let phase, let endsAt) = state else { return false }
        let left = endsAt.timeIntervalSince(now())
        if left <= 0 {
            finish(phase, alert: true)
        } else {
            transition(to: .paused(phase, remaining: max(1, left)))
        }
        return true
    }

    @discardableResult
    func resume() -> Bool {
        guard case .paused(let phase, let remaining) = state else { return false }
        transition(to: .running(phase, endsAt: now().addingTimeInterval(remaining)))
        return true
    }

    /// Ends the current phase now, as if it had run out, but without the
    /// alert. A skipped focus session still counts towards the long break.
    @discardableResult
    func skip() -> Bool {
        guard let phase = state.phase else { return false }
        finish(phase, alert: false)
        return true
    }

    /// Back to idle, and the cycle starts over.
    @discardableResult
    func stop() -> Bool {
        guard state != .idle || completedFocusSessions > 0 else { return false }
        completedFocusSessions = 0
        transition(to: .idle)
        return true
    }

    // MARK: Reading

    /// Time left in the current phase; nil when idle.
    func remaining() -> TimeInterval? {
        switch state {
        case .idle: return nil
        case .running(_, let endsAt): return max(0, endsAt.timeIntervalSince(now()))
        case .paused(_, let remaining): return remaining
        }
    }

    /// e.g. "Focus 2 of 4, 18:42 left" or "Short break, paused, 3:10 left".
    var summary: String {
        guard let phase = state.phase, let remaining = remaining() else { return "Pomodoro" }
        let total = Config.pomodoroSessionsBeforeLongBreak
        var parts: [String]
        switch phase {
        case .focus: parts = ["Focus \(min(completedFocusSessions + 1, total)) of \(total)"]
        case .shortBreak: parts = ["Short break, \(completedFocusSessions) of \(total) done"]
        case .longBreak: parts = ["Long break"]
        }
        if state.isPaused { parts.append("paused") }
        parts.append("\(Self.format(remaining)) left")
        return parts.joined(separator: ", ")
    }

    /// m:ss, rounded up so the last second reads 0:01 rather than 0:00.
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%ld:%02ld", total / 60, total % 60)
    }

    // MARK: Phases

    /// Moves on from `phase`: a focus session leads to a break (started
    /// right away when `autoStart` is on, otherwise waiting paused), a break
    /// back to idle.
    private func finish(_ phase: PomodoroPhase, alert: Bool, autoStart: Bool = Config.pomodoroAutoStartBreaks) {
        switch phase {
        case .focus:
            completedFocusSessions += 1
            let next: PomodoroPhase =
                completedFocusSessions >= Config.pomodoroSessionsBeforeLongBreak ? .longBreak : .shortBreak
            transition(to: autoStart
                ? .running(next, endsAt: now().addingTimeInterval(next.duration))
                : .paused(next, remaining: next.duration))
        case .shortBreak:
            transition(to: .idle)
        case .longBreak:
            completedFocusSessions = 0
            transition(to: .idle)
        }
        if alert { onPhaseEnd?(phase) }
    }

    private func transition(to newState: PomodoroState) {
        state = newState
        updateTicker()
        save()
        onChange?()
    }

    /// A one-second timer, only while running. Restarted on each change so
    /// ticks line up with whole seconds of the countdown. Added in the common
    /// run loop mode so the menu bar title keeps counting while a menu is open.
    private func updateTicker() {
        ticker?.invalidate()
        ticker = nil
        guard case .running = state else { return }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Time left is always worked out from the end date, so a late tick (or
    /// the Mac waking from sleep) just catches up.
    @objc private func tick() {
        guard case .running(let phase, let endsAt) = state else { return }
        if endsAt.timeIntervalSince(now()) <= 0 {
            finish(phase, alert: true)
        } else {
            onChange?()
        }
    }

    /// A phase that ran out during sleep ends (with its alert) right away.
    /// Otherwise the ticker is restarted on purpose: the old one would catch
    /// up by itself, but its ticks no longer line up with whole seconds of
    /// the countdown, so the menu bar title would change mid-second. (A phase
    /// change has already restarted it.)
    @objc private func systemDidWake() {
        let before = state
        tick()
        if state == before { updateTicker() }
    }

    #if SELFTEST
    func tickForSelfTest() { tick() }
    #endif

    // MARK: Saving

    private func save() {
        var stored = StoredPomodoro(phase: state.phase, completedFocusSessions: completedFocusSessions)
        switch state {
        case .idle: break
        case .running(_, let endsAt): stored.endsAt = endsAt
        case .paused(_, let remaining): stored.remaining = remaining
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Launcher: could not save the pomodoro timer: \(error)")
        }
    }

    /// Picks up where the last run left off. A phase that ran out while the
    /// app wasn't running moves on quietly, and the next one waits paused
    /// rather than starting unseen.
    private func restore() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(StoredPomodoro.self, from: data) else { return }

        let longest = max(
            TimeInterval(PomodoroCommand.maxMinutes * 60),
            Config.pomodoroFocus, Config.pomodoroShortBreak, Config.pomodoroLongBreak
        )
        completedFocusSessions = min(max(0, stored.completedFocusSessions), Config.pomodoroSessionsBeforeLongBreak)

        switch (stored.phase, stored.endsAt, stored.remaining) {
        case (let phase?, let endsAt?, nil) where endsAt.timeIntervalSince(now()) <= longest:
            state = .running(phase, endsAt: endsAt)
            if endsAt.timeIntervalSince(now()) <= 0 {
                finish(phase, alert: false, autoStart: false)
            }
        case (let phase?, nil, let remaining?) where remaining > 0 && remaining <= longest:
            state = .paused(phase, remaining: remaining)
        default:
            state = .idle
        }
        updateTicker()
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

/// pomodoro.json: the phase with its end date (running) or time left
/// (paused), and the cycle count.
private struct StoredPomodoro: Codable {
    var phase: PomodoroPhase?
    var endsAt: Date?
    var remaining: TimeInterval?
    var completedFocusSessions: Int
}
