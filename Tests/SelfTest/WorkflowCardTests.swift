// WorkflowCardTests.swift
//
// The command cards under the empty launcher input: one per keyword (both
// forms on one card), the most run first, and a click that types the
// command and hides them. Assumes the shipped prefix, "/".

import Foundation

@MainActor
enum WorkflowCardTests {
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        SelfTest.check("workflow cards: \(name)", condition, detail())
    }

    private static let json = #"""
    {"workflows": [
      {"keywords": ["pr"], "title": "PR", "url": "https://example.com/pr/{query}"},
      {"keywords": ["weather"], "title": "Weather here", "url": "https://example.com/w"},
      {"keywords": ["weather", "w"], "title": "Weather in", "url": "https://example.com/w/{query}"},
      {"keywords": ["zz"], "title": "Sleep", "url": "alfresco://system/sleep"},
      {"keywords": ["cf"], "title": "Contentful", "url": "https://example.com/cf/{query}"}
    ]}
    """#

    static func run() {
        guard Config.commandPrefix == "/" else {
            check("the shipped prefix is /", false, "got \(Config.commandPrefix ?? "nil")")
            return
        }
        guard let set = try? JSONDecoder().decode(WorkflowSet.self, from: Data(json.utf8)) else {
            check("the test workflows decode", false)
            return
        }

        let unused = WorkflowCard.cards(from: set, usage: UsageTotals(), limit: 12)
        check("one card per keyword, in file order when nothing was run",
              unused.map(\.keyword) == ["pr", "weather", "zz", "cf"], "\(unused.map(\.keyword))")
        let weather = unused.first { $0.keyword == "weather" }
        check("a keyword with both forms shows the bare form's title",
              weather?.title == "Weather here", weather?.title ?? "nil")
        check("a keyword with an argument form completes with a space",
              unused.first?.completion == "/pr " && weather?.completion == "/weather ",
              "\(unused.map(\.completion))")
        check("a keyword with only the bare form completes without one",
              unused.first { $0.keyword == "zz" }?.completion == "/zz")

        var usage = UsageTotals()
        usage.keywords = ["zz": 3, "weather": 2, "weather …": 2, "cf …": 1, "pr": 9]
        let used = WorkflowCard.cards(from: set, usage: usage, limit: 12)
        // weather: 2 + 2; "pr" bare never ran (no such form), so pr is 0.
        check("sorted by runs of both forms, most first, file order on ties",
              used.map(\.keyword) == ["weather", "zz", "cf", "pr"], "\(used.map(\.keyword))")
        check("the limit keeps the most run",
              WorkflowCard.cards(from: set, usage: usage, limit: 2).map(\.keyword) == ["weather", "zz"])
        check("a limit of 0 shows none", WorkflowCard.cards(from: set, usage: usage, limit: 0).isEmpty)

        launcher()
    }

    /// The real LauncherController on the test file: shown on empty input,
    /// gone once something is typed, and a click types the command.
    private static func launcher() {
        let url = SelfTest.scratchFile("cards-workflows")
        do {
            try Data(json.utf8).write(to: url)
        } catch {
            check("the test workflows file is written", false, error.localizedDescription)
            return
        }
        let controller = LauncherController(
            store: WorkflowStore(fileURL: url, createsMissingFile: false), internalURLHandler: { _ in false }
        )
        guard let limit = Config.workflowCardLimit, limit > 0 else {
            controller.typeForSelfTest("")
            check("cards are off: none shown", controller.cardKeywordsForSelfTest == nil)
            return
        }
        controller.typeForSelfTest("")
        let shown = controller.cardKeywordsForSelfTest
        check("empty input shows the cards", shown == Array(["pr", "weather", "zz", "cf"].prefix(limit)),
              "\(shown.map { "\($0)" } ?? "nil")")
        controller.typeForSelfTest("  ")
        check("spaces alone still show them", controller.cardKeywordsForSelfTest != nil)
        controller.typeForSelfTest("saf")
        check("typing hides them", controller.cardKeywordsForSelfTest == nil)
        controller.typeForSelfTest("/")
        check("the command list hides them", controller.cardKeywordsForSelfTest == nil)

        controller.typeForSelfTest("")
        guard let index = controller.cardKeywordsForSelfTest?.firstIndex(of: "weather") else {
            check("the weather card is shown to click", false)
            return
        }
        controller.clickCardForSelfTest(index)
        check("a click types the command", controller.inputForSelfTest == "/weather ", controller.inputForSelfTest)
        check("and hides the cards", controller.cardKeywordsForSelfTest == nil)

        // The weather strip above the input: a click types the bare keyword,
        // whatever was typed, which opens the forecast for the strip's place.
        let forecast = CommandInput.typed(Config.weatherKeyword)
        for typed in ["", "/weather lyon", "saf"] {
            controller.typeForSelfTest(typed)
            controller.clickWeatherStripForSelfTest()
            SelfTest.check("weather strip: a click on \"\(typed)\" types \(forecast)",
                           controller.inputForSelfTest == forecast, controller.inputForSelfTest)
        }
        SelfTest.check("weather strip: and hides the cards", controller.cardKeywordsForSelfTest == nil)

        meetingStrip(withoutCalendar: controller)
    }

    /// The next meeting above the input: hidden without calendar access
    /// (the test build never asks for it), and a click with no `cal`
    /// workflow beeps and leaves the input alone. A click that types `/cal`
    /// isn't driven here: the test bundle has the calendar usage
    /// description, so `/cal` would bring up the permission prompt.
    private static func meetingStrip(withoutCalendar controller: LauncherController) {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            SelfTest.check("next meeting: \(name)", condition, detail())
        }
        controller.typeForSelfTest("")
        controller.updateMeetingStripForSelfTest()
        check("hidden without calendar access", controller.meetingStripForSelfTest == nil,
              controller.meetingStripForSelfTest ?? "")
        controller.typeForSelfTest("saf")
        controller.clickMeetingStripForSelfTest()
        check("a click without a cal workflow leaves the input", controller.inputForSelfTest == "saf",
              controller.inputForSelfTest)
    }
}
