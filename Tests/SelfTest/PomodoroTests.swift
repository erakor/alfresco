// PomodoroTests.swift
//
// The pomodoro timer at run time: the menu bar item, the alert's sound and
// notification, restoring pomodoro.json, and catching up after sleep. The
// timer runs on a test clock, so nothing waits real minutes.

import Cocoa
import UserNotifications

@MainActor
private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }
}

/// Stands in for NSSound and UNUserNotificationCenter.
@MainActor
private final class AlertRecorder: PomodoroAlertSink {
    var sounds: [String] = []
    var notifications: [(title: String, body: String)] = []

    func playSound(named name: String) {
        sounds.append(name)
    }

    func notify(title: String, body: String) {
        notifications.append((title: title, body: body))
    }

    func reset() {
        sounds = []
        notifications = []
    }
}

@MainActor
enum PomodoroTests {
    private static let recorder = AlertRecorder()
    /// One notification per alert inside the bundle, none in a plain binary.
    private static var notificationsPerAlert: Int { PomodoroAlert.notificationsAvailableForSelfTest ? 1 : 0 }

    static func run() {
        PomodoroAlert.sink = recorder
        alertResources()
        messages()
        statusItemFollowsTimer()
        naturalPhaseEnds()
        pauseAfterTheEnd()
        wakeFromSleep()
        restoreFromFile()
        startMenuItemValidation()
    }

    // MARK: Helpers

    /// Each timer gets its own wake notification center, so a wake posted
    /// for one check never reaches a timer another check left behind.
    private static func makeTimer(
        _ clock: TestClock, file: URL? = nil, wakeNotifications: NotificationCenter = NotificationCenter()
    ) -> PomodoroTimer {
        PomodoroTimer(
            fileURL: file ?? SelfTest.scratchFile("pomodoro"), now: { clock.date },
            wakeNotifications: wakeNotifications)
    }

    private static func title(_ seconds: TimeInterval) -> String {
        " " + PomodoroTimer.format(seconds)
    }

    private static func minutes(_ phase: PomodoroPhase) -> Int {
        Int((phase.duration / 60).rounded())
    }

    /// Picks a menu item the way a click does.
    private static func perform(_ item: PomodoroStatusItem, _ title: String) {
        let menu = item.menuForSelfTest
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
            check("status item: menu has \"\(title)\"", false, "menu is \(item.menuTitles)")
            return
        }
        menu.performActionForItem(at: index)
    }

    // MARK: Alert

    private static func alertResources() {
        // Set by run-self-tests.sh, so a plain binary mistaken for a bundled
        // one (or the reverse) fails instead of skipping the other branch.
        if let expected = ProcessInfo.processInfo.environment["SELFTEST_EXPECT_BUNDLE"] {
            let bundled = expected == "1"
            check("run: \(bundled ? "inside" : "outside") an app bundle, as expected",
                  PomodoroAlert.notificationsAvailableForSelfTest == bundled,
                  "bundle ID is \(Bundle.main.bundleIdentifier ?? "nil")")
            if bundled {
                check("run: the test bundle has its own bundle ID",
                      Bundle.main.bundleIdentifier == "local.launcher.selftest",
                      "got \(Bundle.main.bundleIdentifier ?? "nil")")
            }
        }
        check("alert: the sound \"\(Config.pomodoroSound)\" exists on this Mac",
              NSSound(named: NSSound.Name(Config.pomodoroSound)) != nil)
        if PomodoroAlert.notificationsAvailableForSelfTest {
            // Raises an Objective-C exception (and crashes the run) when the
            // bundle isn't set up for notifications.
            _ = UNUserNotificationCenter.current()
            check("alert: UNUserNotificationCenter is reachable inside the bundle", true)
        } else {
            check("alert: notifications are off in a plain binary", Bundle.main.bundleIdentifier == nil)
        }
    }

    private static func messages() {
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        func expect(_ name: String, _ phase: PomodoroPhase, _ next: PomodoroState, _ title: String, _ body: String) {
            let message = PomodoroAlert.messageForSelfTest(ended: phase, next: next)
            check("message: \(name)", message.title == title && message.body == body,
                  "got \"\(message.title)\" / \"\(message.body)\"")
        }
        expect("focus, then a running break", .focus, .running(.shortBreak, endsAt: later),
               "Focus session done", "Time for a \(minutes(.shortBreak)) min break.")
        expect("focus, then a paused break", .focus, .paused(.shortBreak, remaining: 60),
               "Focus session done", "Your \(minutes(.shortBreak)) min break is waiting in the menu bar.")
        expect("focus, then a running long break", .focus, .running(.longBreak, endsAt: later),
               "Focus session done", "Time for a \(minutes(.longBreak)) min long break.")
        expect("focus, then a paused long break", .focus, .paused(.longBreak, remaining: 60),
               "Focus session done", "Your \(minutes(.longBreak)) min long break is waiting in the menu bar.")
        expect("short break", .shortBreak, .idle, "Break over", "Ready for the next focus session.")
        expect("long break", .longBreak, .idle, "Long break over", "Cycle complete. Start a new one when you're ready.")
    }

    // MARK: Menu bar

    private static func statusItemFollowsTimer() {
        recorder.reset()
        let clock = TestClock()
        let timer = makeTimer(clock)
        let item = PomodoroStatusItem(timer: timer)
        timer.connect(to: item)

        check("status item: hidden while idle", !item.isShown)

        timer.startFocus()
        check("status item: shown once a focus session starts", item.isShown)
        check("status item: focus shows the timer symbol", item.symbolName == "timer",
              "got \(item.symbolName ?? "nil")")
        check("status item: title starts at the focus length", item.buttonTitle == title(Config.pomodoroFocus),
              "got \(item.buttonTitle ?? "nil")")
        clock.advance(10)
        timer.tickForSelfTest()
        check("status item: title counts down", item.buttonTitle == title(Config.pomodoroFocus - 10),
              "got \(item.buttonTitle ?? "nil")")
        check("status item: menu offers Pause, Skip to Break and Stop",
              ["Pause", "Skip to Break", "Stop"].allSatisfy { item.menuTitles.contains($0) }, "menu is \(item.menuTitles)")
        check("status item: not dimmed while running", !item.appearsDisabled)

        perform(item, "Pause")
        check("status item: Pause pauses the timer", timer.state.isPaused, "state is \(timer.state)")
        check("status item: paused menu offers Resume", item.menuTitles.contains("Resume"), "menu is \(item.menuTitles)")
        check("status item: dimmed while paused", item.appearsDisabled)
        check("status item: status line says paused", item.menuTitles.first?.contains("paused") == true,
              "got \(item.menuTitles.first ?? "nil")")

        perform(item, "Resume")
        check("status item: Resume runs the timer again", timer.state == .running(
            .focus, endsAt: clock.date.addingTimeInterval(Config.pomodoroFocus - 10)), "state is \(timer.state)")
        check("status item: not dimmed after resuming", !item.appearsDisabled)

        perform(item, "Skip to Break")
        check("status item: Skip to Break starts the break", timer.state.phase == .shortBreak, "state is \(timer.state)")
        check("status item: a break shows the cup symbol", item.symbolName == "cup.and.saucer",
              "got \(item.symbolName ?? "nil")")
        check("status item: a break's menu offers End Break", item.menuTitles.contains("End Break"),
              "menu is \(item.menuTitles)")
        check("alert: skipping plays no sound and posts nothing",
              recorder.sounds.isEmpty && recorder.notifications.isEmpty)

        perform(item, "Stop")
        check("status item: Stop makes the timer idle", timer.state == .idle, "state is \(timer.state)")
        check("status item: removed when idle", !item.isShown)
        check("alert: stopping plays no sound and posts nothing",
              recorder.sounds.isEmpty && recorder.notifications.isEmpty)
    }

    // MARK: Phase ends

    private static func naturalPhaseEnds() {
        recorder.reset()
        let clock = TestClock()
        let timer = makeTimer(clock)
        let item = PomodoroStatusItem(timer: timer)
        timer.connect(to: item)

        timer.startFocus()
        clock.advance(Config.pomodoroFocus + 1)
        timer.tickForSelfTest()
        let breakState: PomodoroState = Config.pomodoroAutoStartBreaks
            ? .running(.shortBreak, endsAt: clock.date.addingTimeInterval(Config.pomodoroShortBreak))
            : .paused(.shortBreak, remaining: Config.pomodoroShortBreak)
        check("phase end: focus leads to a short break", timer.state == breakState, "state is \(timer.state)")
        check("phase end: focus plays the sound once", recorder.sounds == [Config.pomodoroSound],
              "sounds \(recorder.sounds)")
        check("phase end: focus posts \(notificationsPerAlert) notification(s)",
              recorder.notifications.count == notificationsPerAlert, "got \(recorder.notifications.count)")
        if let note = recorder.notifications.last {
            let expected = PomodoroAlert.messageForSelfTest(ended: .focus, next: timer.state)
            check("phase end: focus notification text", note.title == expected.title && note.body == expected.body,
                  "got \"\(note.title)\" / \"\(note.body)\"")
        }
        timer.tickForSelfTest()
        check("phase end: the next tick doesn't alert again", recorder.sounds.count == 1,
              "sounds \(recorder.sounds)")

        if Config.pomodoroAutoStartBreaks {
            clock.advance(Config.pomodoroShortBreak + 1)
            timer.tickForSelfTest()
            check("phase end: a short break leads to idle", timer.state == .idle, "state is \(timer.state)")
            check("phase end: a short break plays the sound", recorder.sounds.count == 2, "sounds \(recorder.sounds)")
            if notificationsPerAlert > 0 {
                check("phase end: short break notification says Break over",
                      recorder.notifications.last?.title == "Break over",
                      "got \(recorder.notifications.last?.title ?? "nil")")
            }
        }

        // A whole cycle: the last focus session leads to the long break.
        timer.stop()
        recorder.reset()
        for _ in 0..<Config.pomodoroSessionsBeforeLongBreak {
            timer.startFocus()
            clock.advance(Config.pomodoroFocus + 1)
            timer.tickForSelfTest()
        }
        check("phase end: focus \(Config.pomodoroSessionsBeforeLongBreak) leads to the long break",
              timer.state.phase == .longBreak, "state is \(timer.state)")
        check("phase end: one sound per focus session",
              recorder.sounds.count == Config.pomodoroSessionsBeforeLongBreak, "sounds \(recorder.sounds)")
        if notificationsPerAlert > 0 {
            check("phase end: the last focus notification mentions the long break",
                  recorder.notifications.last?.body.contains("long break") == true,
                  "got \(recorder.notifications.last?.body ?? "nil")")
        }
        if Config.pomodoroAutoStartBreaks {
            clock.advance(Config.pomodoroLongBreak + 1)
            timer.tickForSelfTest()
            check("phase end: the long break leads to idle", timer.state == .idle, "state is \(timer.state)")
            check("phase end: the long break resets the cycle", timer.completedFocusSessions == 0,
                  "count \(timer.completedFocusSessions)")
            if notificationsPerAlert > 0 {
                check("phase end: long break notification says Long break over",
                      recorder.notifications.last?.title == "Long break over",
                      "got \(recorder.notifications.last?.title ?? "nil")")
            }
        }
        timer.stop()
    }

    /// Pausing after the end has passed (before the tick noticed) finishes
    /// the phase rather than pausing it with time left.
    private static func pauseAfterTheEnd() {
        recorder.reset()
        let clock = TestClock()
        let timer = makeTimer(clock)
        let item = PomodoroStatusItem(timer: timer)
        timer.connect(to: item)

        timer.startFocus()
        clock.advance(Config.pomodoroFocus + 5)
        check("pause after the end: accepted", timer.pause())
        check("pause after the end: the phase finishes", timer.state.phase == .shortBreak, "state is \(timer.state)")
        check("pause after the end: alerts once", recorder.sounds.count == 1, "sounds \(recorder.sounds)")
        timer.stop()
    }

    // MARK: Sleep

    private static func wakeFromSleep() {
        recorder.reset()
        let clock = TestClock()
        let wake = NotificationCenter()
        let timer = makeTimer(clock, wakeNotifications: wake)
        let item = PomodoroStatusItem(timer: timer)
        timer.connect(to: item)

        // Asleep through the end of the session: waking finishes it at once.
        timer.startFocus()
        clock.advance(Config.pomodoroFocus + 30)
        wake.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        check("wake: a session that ended during sleep finishes on wake", timer.state.phase == .shortBreak,
              "state is \(timer.state)")
        if case .running(_, let endsAt) = timer.state {
            check("wake: the break is timed from the wake", endsAt == clock.date.addingTimeInterval(Config.pomodoroShortBreak),
                  "ends \(endsAt), now \(clock.date)")
        }
        check("wake: alerts once", recorder.sounds.count == 1, "sounds \(recorder.sounds)")
        check("wake: posts \(notificationsPerAlert) notification(s)",
              recorder.notifications.count == notificationsPerAlert, "got \(recorder.notifications.count)")
        timer.tickForSelfTest()
        check("wake: the next tick doesn't alert again", recorder.sounds.count == 1, "sounds \(recorder.sounds)")

        // Asleep for part of a session: waking just updates the countdown.
        recorder.reset()
        timer.startFocus()
        clock.advance(60)
        wake.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        check("wake: a session with time left keeps running", timer.state == .running(
            .focus, endsAt: clock.date.addingTimeInterval(Config.pomodoroFocus - 60)), "state is \(timer.state)")
        check("wake: the menu bar shows the time left", item.buttonTitle == title(Config.pomodoroFocus - 60),
              "got \(item.buttonTitle ?? "nil")")
        check("wake: no alert while time is left", recorder.sounds.isEmpty, "sounds \(recorder.sounds)")

        // A paused session isn't touched by waking.
        timer.pause()
        let paused = timer.state
        clock.advance(Config.pomodoroFocus * 2)
        wake.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        check("wake: a paused session stays paused", timer.state == paused, "state is \(timer.state)")
        timer.stop()
    }

    // MARK: Restore

    private static func restoreFromFile() {
        recorder.reset()
        let clock = TestClock()
        let iso = ISO8601DateFormatter()
        func restored(_ json: String) -> PomodoroTimer {
            let file = SelfTest.scratchFile("restore")
            try? Data(json.utf8).write(to: file)
            return makeTimer(clock, file: file)
        }
        func expect(_ name: String, _ json: String, _ state: PomodoroState, count: Int? = nil) {
            let timer = restored(json)
            check("restore: \(name)", timer.state == state, "state is \(timer.state)")
            if let count {
                check("restore: \(name), cycle count", timer.completedFocusSessions == count,
                      "count \(timer.completedFocusSessions)")
            }
            timer.stop()
        }
        let future = clock.date.addingTimeInterval(600)
        let past = clock.date.addingTimeInterval(-60)
        let farFuture = clock.date.addingTimeInterval(200 * 24 * 3600)
        let longBreakAfter = Config.pomodoroSessionsBeforeLongBreak - 1

        expect("running, end still ahead",
               #"{"phase":"focus","endsAt":"\#(iso.string(from: future))","completedFocusSessions":2}"#,
               .running(.focus, endsAt: future), count: 2)
        expect("running, ended while quit: the break waits paused",
               #"{"phase":"focus","endsAt":"\#(iso.string(from: past))","completedFocusSessions":1}"#,
               .paused(.shortBreak, remaining: Config.pomodoroShortBreak), count: 2)
        expect("running, ended while quit: the long break when due",
               #"{"phase":"focus","endsAt":"\#(iso.string(from: past))","completedFocusSessions":\#(longBreakAfter)}"#,
               .paused(.longBreak, remaining: Config.pomodoroLongBreak))
        expect("running break, ended while quit: idle",
               #"{"phase":"shortBreak","endsAt":"\#(iso.string(from: past))","completedFocusSessions":1}"#,
               .idle)
        expect("paused",
               #"{"phase":"shortBreak","remaining":120,"completedFocusSessions":1}"#,
               .paused(.shortBreak, remaining: 120), count: 1)
        expect("end too far ahead: idle",
               #"{"phase":"focus","endsAt":"\#(iso.string(from: farFuture))","completedFocusSessions":0}"#,
               .idle)
        expect("paused, too long: idle", #"{"phase":"focus","remaining":10000000,"completedFocusSessions":0}"#, .idle)
        expect("paused, negative: idle", #"{"phase":"focus","remaining":-5,"completedFocusSessions":0}"#, .idle)
        expect("paused, zero: idle", #"{"phase":"focus","remaining":0,"completedFocusSessions":0}"#, .idle)
        expect("both an end and time left: idle",
               #"{"phase":"focus","endsAt":"\#(iso.string(from: future))","remaining":60,"completedFocusSessions":0}"#,
               .idle)
        expect("unknown phase: idle", #"{"phase":"nap","remaining":60,"completedFocusSessions":0}"#, .idle, count: 0)
        expect("corrupt JSON: idle", "{not json", .idle, count: 0)
        expect("cycle count too high: clamped",
               #"{"phase":"focus","remaining":60,"completedFocusSessions":99}"#,
               .paused(.focus, remaining: 60), count: Config.pomodoroSessionsBeforeLongBreak)
        expect("cycle count negative: clamped",
               #"{"phase":"focus","remaining":60,"completedFocusSessions":-3}"#,
               .paused(.focus, remaining: 60), count: 0)

        let missing = makeTimer(clock, file: SelfTest.scratchFile("missing"))
        check("restore: no file: idle", missing.state == .idle, "state is \(missing.state)")

        // What the timer saves, a new one reads back.
        let file = SelfTest.scratchFile("roundtrip")
        let first = makeTimer(clock, file: file)
        first.startFocus(minutes: 10)
        let running = first.state
        check("restore: a running session survives a relaunch", makeTimer(clock, file: file).state == running,
              "saved \(running)")
        clock.advance(30)
        first.pause()
        let paused = first.state
        let second = makeTimer(clock, file: file)
        check("restore: a paused session survives a relaunch", second.state == paused,
              "saved \(paused), read \(second.state)")
        check("restore: plays no alert", recorder.sounds.isEmpty && recorder.notifications.isEmpty)
        first.stop()
        second.stop()
    }

    // MARK: App menu

    /// "Start Pomodoro" in the app's menu is disabled while a session runs,
    /// through NSMenu's own validation.
    private static func startMenuItemValidation() {
        let clock = TestClock()
        let timer = makeTimer(clock)
        let delegate = AppDelegate()
        delegate.useForSelfTest(pomodoro: timer)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Start Pomodoro", action: AppDelegate.startPomodoroAction, keyEquivalent: "")
        item.target = delegate
        menu.addItem(item)

        menu.update()
        check("app menu: Start Pomodoro enabled while idle", item.isEnabled)
        timer.startFocus()
        menu.update()
        check("app menu: Start Pomodoro disabled while running", !item.isEnabled)
        timer.pause()
        menu.update()
        check("app menu: Start Pomodoro disabled while paused", !item.isEnabled)
        timer.stop()
        menu.update()
        check("app menu: Start Pomodoro enabled again after Stop", item.isEnabled)
    }

    // MARK: Relaunch (two processes)

    /// First process: a 1 minute focus session, paused, saved to the scratch
    /// folder's pomodoro.json.
    static func relaunchWrite() {
        let timer = PomodoroTimer()
        timer.stop()
        timer.startFocus(minutes: 1)
        check("relaunch-write: a 1 minute session runs", timer.state.phase == .focus && !timer.state.isPaused,
              "state is \(timer.state)")
        timer.pause()
        check("relaunch-write: paused", timer.state.isPaused, "state is \(timer.state)")
    }

    /// Second process: the paused session is back, and so is its menu bar item.
    static func relaunchRead() {
        let timer = PomodoroTimer()
        let item = PomodoroStatusItem(timer: timer)
        timer.connect(to: item)
        check("relaunch-read: the paused focus session is back", timer.state.phase == .focus && timer.state.isPaused,
              "state is \(timer.state)")
        let remaining = timer.remaining() ?? 0
        check("relaunch-read: about a minute left", remaining > 50 && remaining <= 60, "remaining \(remaining)")
        check("relaunch-read: the menu bar item is back", item.isShown)
        check("relaunch-read: the menu bar shows the time left", [" 1:00", " 0:59"].contains(item.buttonTitle ?? ""),
              "got \(item.buttonTitle ?? "nil")")
        check("relaunch-read: the menu offers Resume", item.menuTitles.contains("Resume"), "menu is \(item.menuTitles)")
        timer.stop()
        check("relaunch-read: Stop removes the menu bar item", !item.isShown)
    }

    // MARK: Screenshot

    private static var heldTimer: PomodoroTimer?
    private static var heldItem: PomodoroStatusItem?

    /// Runs a real focus session for SELFTEST_HOLD_SECONDS (default 15) so
    /// a screenshot can show the menu bar item, then exits.
    static func menuBarHold() {
        let timer = PomodoroTimer()
        let item = PomodoroStatusItem(timer: timer)
        timer.connect(to: item)
        timer.startFocus()
        heldTimer = timer
        heldItem = item
        let seconds = Double(ProcessInfo.processInfo.environment["SELFTEST_HOLD_SECONDS"] ?? "") ?? 15
        SelfTest.log("HOLDING \(item.buttonTitle ?? "nil") for \(Int(seconds)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                let shown = heldItem?.isShown ?? false
                let title = heldItem?.buttonTitle ?? "nil"
                heldTimer?.stop()
                check("menubar-hold: the item was still shown, reading \(title)", shown)
                SelfTest.finish()
            }
        }
    }
}
