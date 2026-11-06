// SuggestionListTests.swift
//
// The launcher's suggestion list: the row under the pointer is hovered,
// the hover never moves the highlight Enter takes, and new rows or leaving
// the list clear it.

import Cocoa

@MainActor
enum SuggestionListTests {
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        SelfTest.check("suggestion list: \(name)", condition, detail())
    }

    private static let json = #"""
    {"workflows": [
      {"keywords": ["pr"], "title": "PR", "url": "https://example.com/pr/{query}"},
      {"keywords": ["pomo"], "title": "Pomodoro", "url": "alfresco://pomodoro/toggle"},
      {"keywords": ["zz"], "title": "Sleep", "url": "alfresco://system/sleep"}
    ]}
    """#

    static func run() {
        guard let set = try? JSONDecoder().decode(WorkflowSet.self, from: Data(json.utf8)) else {
            check("the test workflows decode", false)
            return
        }
        let items = set.workflows.compactMap { workflow in
            workflow.keywords.first.map { LauncherItem.workflow(Suggestion(keyword: $0, workflow: workflow)) }
        }
        let list = SuggestionListView(frame: .zero)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: true
        )
        list.show(items)
        list.frame = NSRect(x: 0, y: 0, width: 600, height: list.preferredHeight)
        window.contentView?.addSubview(list)
        list.layoutSubtreeIfNeeded()
        check("three rows to hover", list.items.count == 3, "\(list.items.count)")

        list.moveMouseForSelfTest(toRow: 1)
        check("the row under the pointer is hovered",
              list.hoveredRowForSelfTest == 1, "\(String(describing: list.hoveredRowForSelfTest))")
        check("hovering doesn't highlight a row for Enter", list.selected == nil)

        list.moveMouseForSelfTest(toRow: 2)
        check("the hover follows the pointer",
              list.hoveredRowForSelfTest == 2, "\(String(describing: list.hoveredRowForSelfTest))")

        list.moveMouseForSelfTest(toRow: nil)
        check("leaving the rows clears the hover", list.hoveredRowForSelfTest == nil)

        list.show(items, highlightFirst: true)
        list.moveMouseForSelfTest(toRow: 2)
        let enterTakesFirst: Bool
        if case .workflow(let suggestion)? = list.selected { enterTakesFirst = suggestion.keyword == "pr" } else { enterTakesFirst = false }
        check("hovering leaves the highlighted row as it was", enterTakesFirst)

        list.show(items)
        check("new rows clear the hover", list.hoveredRowForSelfTest == nil)
        withExtendedLifetime(window) {}
    }
}
