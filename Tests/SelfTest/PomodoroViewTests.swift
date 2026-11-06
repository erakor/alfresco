// PomodoroViewTests.swift
//
// The pomodoro view under the launcher input: today's finished focus
// sessions (counted, saved and restored by the timer), what Enter would do
// (PomodoroCommand.preview), what the view shows, and the real
// LauncherController showing it for `/pomo` with the hint to match.
// Assumes the shipped prefix, "/".

import Foundation

@MainActor
enum PomodoroViewTests {
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        SelfTest.check("pomodoro view: \(name)", condition, detail())
    }

    /// Days in UTC, so day boundaries don't depend on the runner's zone.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2027-01-15 08:00 UTC, TestClock's default.
    private static let morning = Date(timeIntervalSince1970: 1_800_000_000)

    private static func makeTimer(_ clock: TestClock, file: URL? = nil) -> PomodoroTimer {
        PomodoroTimer(
            fileURL: file ?? SelfTest.scratchFile("pomodoro-view"), now: { clock.date },
            wakeNotifications: NotificationCenter(), calendar: utc)
    }

    static func run() {
        sessionsToday()
        previews()
        content()
        launcher()
    }

    // MARK: Today's sessions

    private static func sessionsToday() {
        let clock = TestClock(morning)
        let file = SelfTest.scratchFile("pomodoro-today")
        let timer = makeTimer(clock, file: file)
        check("none finished yet", timer.focusSessionsToday == 0, "\(timer.focusSessionsToday)")

        timer.startFocus()
        clock.advance(Config.pomodoroFocus + 1)
        timer.tickForSelfTest()
        check("a focus session that runs out counts", timer.focusSessionsToday == 1, "\(timer.focusSessionsToday)")

        timer.skip() // the break
        timer.startFocus()
        timer.skip()
        check("a skipped one doesn't", timer.focusSessionsToday == 1 && timer.completedFocusSessions == 2,
              "today \(timer.focusSessionsToday), cycle \(timer.completedFocusSessions)")

        timer.stop()
        check("stop keeps today's count", timer.focusSessionsToday == 1, "\(timer.focusSessionsToday)")
        check("and it survives a relaunch", makeTimer(clock, file: file).focusSessionsToday == 1)

        clock.advance(24 * 3600)
        check("the next day starts at none", timer.focusSessionsToday == 0, "\(timer.focusSessionsToday)")
        timer.startFocus(minutes: 1)
        clock.advance(61)
        timer.tickForSelfTest()
        check("then counts again from one", timer.focusSessionsToday == 1, "\(timer.focusSessionsToday)")
        timer.stop()

        // Ended at 23:55 while the app was closed, noticed at 00:30: it was
        // yesterday's.
        let iso = ISO8601DateFormatter()
        let lateEnd = utc.date(bySettingHour: 23, minute: 55, second: 0, of: morning)!
        let restoredFile = SelfTest.scratchFile("pomodoro-today-restore")
        try? Data(#"{"phase":"focus","endsAt":"\#(iso.string(from: lateEnd))","completedFocusSessions":0}"#.utf8)
            .write(to: restoredFile)
        let nextDay = TestClock(lateEnd.addingTimeInterval(35 * 60))
        let restored = makeTimer(nextDay, file: restoredFile)
        check("a session restored after midnight counts for the day it ended",
              restored.focusSessionsToday == 0 && restored.completedFocusSessions == 1,
              "today \(restored.focusSessionsToday), cycle \(restored.completedFocusSessions)")
        nextDay.date = lateEnd.addingTimeInterval(60)
        check("which is the day before", restored.focusSessionsToday == 1, "\(restored.focusSessionsToday)")
        restored.stop()

        let older = SelfTest.scratchFile("pomodoro-today-old")
        try? Data(#"{"phase":"focus","remaining":60,"completedFocusSessions":1}"#.utf8).write(to: older)
        check("a file from an older build reads as none today", makeTimer(clock, file: older).focusSessionsToday == 0)
        let huge = SelfTest.scratchFile("pomodoro-today-huge")
        try? Data(#"{"completedFocusSessions":0,"lastFocusEnd":"\#(iso.string(from: clock.date))","focusSessionsOnLastDay":999999}"#.utf8)
            .write(to: huge)
        check("an impossible count is clamped", makeTimer(clock, file: huge).focusSessionsToday == 24 * 60)
    }

    // MARK: What Enter would do

    private static func previews() {
        let running = PomodoroState.running(.focus, endsAt: morning)
        let paused = PomodoroState.paused(.shortBreak, remaining: 60)
        let focus = PomodoroPhase.focus.minutes
        func expect(_ name: String, _ command: PomodoroCommand?, _ state: PomodoroState, done: Int = 0,
                    _ text: String, runs: Bool) {
            let preview = PomodoroCommand.preview(of: command, state: state, completedFocusSessions: done)
            check("Enter: \(name)", preview == PomodoroCommand.Preview(text: text, runs: runs),
                  "got \"\(preview.text)\", runs \(preview.runs)")
        }
        expect("toggle while idle starts", .toggle, .idle, "Start a \(focus) min focus session", runs: true)
        expect("toggle while running pauses", .toggle, running, "Pause the focus session", runs: true)
        expect("toggle while paused resumes", .toggle, paused, "Resume the short break", runs: true)
        expect("minutes while idle", .start(minutes: 50), .idle, "Start a 50 min focus session", runs: true)
        expect("minutes while running replace it", .start(minutes: 50), running,
               "Replace the focus session with a 50 min focus session", runs: true)
        expect("pause while idle", .pause, .idle, "Nothing to pause", runs: false)
        expect("pause while paused", .pause, paused, "Already paused", runs: false)
        expect("resume while running", .resume, running, "Already running", runs: false)
        expect("skip a focus session", .skip, running, "Skip to the break", runs: true)
        expect("skip a break", .skip, paused, "End the short break", runs: true)
        expect("skip while idle", .skip, .idle, "Nothing to skip", runs: false)
        expect("stop while running", .stop, running, "Stop the focus session and reset the cycle", runs: true)
        expect("stop while idle mid-cycle", .stop, .idle, done: 2, "Reset the cycle", runs: true)
        expect("stop while idle", .stop, .idle, "Nothing to stop", runs: false)
        let unknown = PomodoroCommand.preview(of: nil, state: .idle, completedFocusSessions: 0)
        check("Enter: an unknown action says what works", !unknown.runs && unknown.hint.contains("minutes"),
              unknown.hint)
        check("Enter: the hint marks what runs with ↩",
              PomodoroCommand.Preview(text: "Pause", runs: true).hint == "↩ Pause"
                  && PomodoroCommand.Preview(text: "Nothing to pause", runs: false).hint == "Nothing to pause")

        // What the hint promises is what the timer does, in every state.
        let commands: [PomodoroCommand] = [.toggle, .start(minutes: nil), .start(minutes: 5), .pause, .resume, .skip, .stop]
        let setups: [(String, @MainActor (PomodoroTimer) -> Void)] = [
            ("idle", { _ in }),
            ("idle mid-cycle", { timer in timer.startFocus(); timer.skip(); timer.skip() }),
            ("running focus", { timer in timer.startFocus() }),
            ("paused focus", { timer in timer.startFocus(); timer.pause() }),
            ("running break", { timer in timer.startFocus(); timer.skip(); timer.resume() }),
            ("paused break", { timer in timer.startFocus(); timer.skip(); timer.resume(); timer.pause() }),
        ]
        for (name, setUp) in setups {
            for command in commands {
                let timer = makeTimer(TestClock())
                setUp(timer)
                let preview = PomodoroCommand.preview(
                    of: command, state: timer.state, completedFocusSessions: timer.completedFocusSessions)
                let ran = timer.run(command)
                check("Enter: \(command) while \(name) runs as the hint says", preview.runs == ran,
                      "hint \"\(preview.hint)\", ran \(ran)")
                timer.stop()
            }
        }
    }

    // MARK: What the view shows

    private static func content() {
        let total = Config.pomodoroSessionsBeforeLongBreak
        let shortBreak = PomodoroPhase.shortBreak.minutes
        let longBreak = PomodoroPhase.longBreak.minutes

        let idle = PomodoroViewContent(
            state: .idle, remaining: nil, completedFocusSessions: 0, sessionsToday: 0,
            startMinutes: 50, endTime: nil)
        check("idle shows the length Enter would start", idle.clock == "50:00", idle.clock)
        check("idle names the first session", idle.tag == "FOCUS 1 OF \(total)" && idle.title == "Not started",
              "\(idle.tag) / \(idle.title)")
        check("idle is neutral", idle.tint == .neutral && idle.symbolName == "timer")
        check("no session today", idle.today == "No focus session finished today", idle.today)
        check("an empty cycle", idle.cycle == String(repeating: "○", count: total), idle.cycle)

        let running = PomodoroViewContent(
            state: .running(.focus, endsAt: morning), remaining: 18 * 60 + 42, completedFocusSessions: 1,
            sessionsToday: 3, startMinutes: 25, endTime: "14:32")
        check("running shows the time left", running.clock == "18:42", running.clock)
        check("running names the session and its end",
              running.tag == "FOCUS 2 OF \(total)" && running.title == "Ends at 14:32",
              "\(running.tag) / \(running.title)")
        check("a focus session is red", running.tint == .focus)
        check("what follows a session", running.detail == "Then a \(shortBreak) min break", running.detail)
        check("today's count", running.today == "3 focus sessions today", running.today)
        check("the cycle so far", running.cycle == "●" + String(repeating: "○", count: total - 1), running.cycle)

        let last = PomodoroViewContent(
            state: .running(.focus, endsAt: morning), remaining: 60, completedFocusSessions: total - 1,
            sessionsToday: 1, startMinutes: 25, endTime: "9:00")
        check("the last session leads to the long break", last.detail == "Then a \(longBreak) min long break",
              last.detail)
        check("one session today", last.today == "1 focus session today", last.today)

        let paused = PomodoroViewContent(
            state: .paused(.shortBreak, remaining: 125), remaining: 125, completedFocusSessions: 1,
            sessionsToday: 1, startMinutes: 25, endTime: nil)
        check("a paused break", paused.tag == "SHORT BREAK" && paused.title == "Paused" && paused.clock == "2:05",
              "\(paused.tag) / \(paused.title) / \(paused.clock)")
        check("paused is neutral, with the break's cup", paused.tint == .neutral && paused.symbolName == "cup.and.saucer")
        check("what follows a break", paused.detail == "Then focus 2 of \(total)", paused.detail)

        let afterCycle = PomodoroViewContent(
            state: .idle, remaining: nil, completedFocusSessions: total, sessionsToday: total,
            startMinutes: 25, endTime: nil)
        check("idle after a full cycle starts a new one", afterCycle.tag == "FOCUS 1 OF \(total)", afterCycle.tag)
    }

    // MARK: In the launcher

    private static let json = #"""
    {"workflows": [
      {"keywords": ["pomo"], "title": "Pomodoro", "url": "alfresco://pomodoro/toggle"},
      {"keywords": ["pomo"], "title": "Pomodoro", "url": "alfresco://pomodoro/{query}"},
      {"keywords": ["focus"], "title": "Long focus", "url": "alfresco://pomodoro/50"},
      {"keywords": ["zz"], "title": "Sleep", "url": "alfresco://system/sleep"}
    ]}
    """#

    private static func launcher() {
        guard Config.commandPrefix == "/" else {
            check("the shipped prefix is /", false, "got \(Config.commandPrefix ?? "nil")")
            return
        }
        let url = SelfTest.scratchFile("pomodoro-workflows")
        do {
            try Data(json.utf8).write(to: url)
        } catch {
            check("the test workflows file is written", false, error.localizedDescription)
            return
        }
        let clock = TestClock(morning)
        let timer = makeTimer(clock)
        let store = WorkflowStore(fileURL: url, createsMissingFile: false)
        let controller = LauncherController(store: store, pomodoro: timer, internalURLHandler: { _ in true })
        let focus = PomodoroPhase.focus.minutes

        controller.typeForSelfTest("/pomo")
        let idle = controller.pomodoroForSelfTest
        check("/pomo shows the view", idle != nil)
        check("idle, it shows the focus length", idle?.clock == PomodoroTimer.format(Config.pomodoroFocus),
              idle?.clock ?? "nil")
        check("the hint says what Enter does", controller.hintForSelfTest == "↩ Start a \(focus) min focus session",
              controller.hintForSelfTest)

        controller.typeForSelfTest("/pomo 50")
        check("/pomo 50 shows 50:00", controller.pomodoroForSelfTest?.clock == "50:00",
              controller.pomodoroForSelfTest?.clock ?? "nil")
        controller.typeForSelfTest("/focus")
        check("another workflow pointing at the timer shows it too",
              controller.pomodoroForSelfTest?.clock == "50:00" && controller.hintForSelfTest == "↩ Start a 50 min focus session",
              "\(controller.pomodoroForSelfTest?.clock ?? "nil") / \(controller.hintForSelfTest)")
        controller.typeForSelfTest("/pomo pause")
        check("an action that wouldn't run says why", controller.hintForSelfTest == "Nothing to pause",
              controller.hintForSelfTest)
        controller.typeForSelfTest("/pomo 500")
        check("an unknown action keeps the view", controller.pomodoroForSelfTest != nil)
        check("and its hint says what works", controller.hintForSelfTest.contains("minutes"), controller.hintForSelfTest)

        timer.startFocus()
        clock.advance(60)
        controller.typeForSelfTest("/pomo")
        let running = controller.pomodoroForSelfTest
        check("running, it counts down",
              running?.clock == PomodoroTimer.format(Config.pomodoroFocus - 60) && running?.tint == .focus,
              running?.clock ?? "nil")
        check("running, Enter pauses", controller.hintForSelfTest == "↩ Pause the focus session",
              controller.hintForSelfTest)
        timer.pause()
        controller.typeForSelfTest("/pomo")
        check("paused, Enter resumes", controller.hintForSelfTest == "↩ Resume the focus session",
              controller.hintForSelfTest)
        timer.stop()

        for other in ["/zz", "/", "", "pomo"] {
            controller.typeForSelfTest(other)
            check("\"\(other)\" doesn't show it", controller.pomodoroForSelfTest == nil)
        }

        let withoutTimer = LauncherController(store: store, internalURLHandler: { _ in true })
        withoutTimer.typeForSelfTest("/pomo")
        check("no timer, no view", withoutTimer.pomodoroForSelfTest == nil)
    }
}
