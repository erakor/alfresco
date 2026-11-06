// SuggestionListTests.swift
//
// The launcher's suggestion list: moving the pointer over a row highlights
// it for Enter, leaving the list keeps it, and new rows reset it.

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

        var hovers = 0
        list.onHover = { hovers += 1 }
        func selected() -> String { String(describing: list.selectedRowForSelfTest) }

        list.moveMouseForSelfTest(toRow: 1)
        check("the row under the pointer is highlighted for Enter",
              list.selectedRowForSelfTest == 1 && hovers == 1, "row \(selected()), \(hovers) hovers")
        list.moveMouseForSelfTest(toRow: 1)
        check("moving within the same row doesn't report a change", hovers == 1, "\(hovers) hovers")

        list.moveMouseForSelfTest(toRow: 2)
        check("the highlight follows the pointer", list.selectedRowForSelfTest == 2, selected())

        list.moveMouseForSelfTest(toRow: nil)
        check("leaving the rows keeps the last one highlighted", list.selectedRowForSelfTest == 2, selected())

        list.moveSelection(by: -1)
        check("↑ goes on from the hovered row", list.selectedRowForSelfTest == 1, selected())

        list.show(items)
        check("new rows drop the hovered highlight", list.selectedRowForSelfTest == nil, selected())

        list.show(items, highlightFirst: true)
        list.moveMouseForSelfTest(toRow: 2)
        check("hovering moves the highlight off the first row",
              list.selectedRowForSelfTest == 2, selected())
        withExtendedLifetime(window) {}
    }
}
