// CommandPrefixTests.swift
//
// Config.commandPrefix: workflow keywords run only after it (`/pr 12`), bare
// words go to the fallback, command input is never searched for, and `/` or
// `/help` lists every command. Assumes the shipped prefix, "/".

import Foundation

@MainActor
enum CommandPrefixTests {
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        SelfTest.check("command prefix: \(name)", condition, detail())
    }

    private static func workflows(_ json: String) -> WorkflowSet? {
        try? JSONDecoder().decode(WorkflowSet.self, from: Data(json.utf8))
    }

    static func run() {
        guard Config.commandPrefix == "/" else {
            check("the shipped prefix is /", false, "got \(Config.commandPrefix ?? "nil")")
            return
        }
        guard let set = workflows(#"""
        {"workflows": [
          {"keywords": ["pr"], "title": "PR", "url": "https://example.com/pr/{query}"},
          {"keywords": ["/cal"], "title": "Calendar", "url": "https://example.com/cal"},
          {"keywords": ["cal"], "title": "Search", "url": "https://example.com/cal?q={query}"},
          {"keywords": ["zz"], "title": "Sleep", "url": "alfresco://system/sleep"}
        ], "fallback": {"title": "Search", "url": "https://example.com/s?q={query}"}}
        """#) else {
            check("the test workflows decode", false)
            return
        }

        // Parsing.
        let pr = CommandParser.parse("/pr 12", using: set)
        check("/pr 12 runs the workflow",
              pr?.url.absoluteString == "https://example.com/pr/12"
                  && pr?.source == CommandSource.workflow(keyword: "pr", withArgument: true),
              pr?.url.absoluteString ?? "nil")
        check("space after the prefix is allowed",
              CommandParser.parse("/ pr 12", using: set)?.url.absoluteString == "https://example.com/pr/12")
        check("a keyword is case-insensitive after the prefix",
              CommandParser.parse("/ZZ", using: set)?.url.absoluteString == "alfresco://system/sleep")
        let bare = CommandParser.parse("pr 12", using: set)
        check("bare pr 12 is a search, not the workflow",
              bare?.isFallback == true && bare?.url.absoluteString == "https://example.com/s?q=pr%2012",
              bare?.url.absoluteString ?? "nil")
        check("bare zz is a search, never sleep", CommandParser.parse("zz", using: set)?.isFallback == true)
        check("bare words are unmatched, so apps and built-ins can take them",
              CommandParser.isUnmatched("zz", using: set) && CommandParser.isUnmatched("pr 12", using: set))
        for input in ["/", "/help", "/nope", "/nope 12", "/pr"] {
            check("\(input) is never searched for",
                  CommandParser.parse(input, using: set) == nil && !CommandParser.isUnmatched(input, using: set))
        }
        check("a keyword written with the prefix in the file is stored without it",
              set.workflow(for: "cal", withArgument: false)?.title == "Calendar" && !set.keywords.contains("/cal"))

        // Waiting for an argument.
        check("/pr alone waits for its argument", set.workflowAwaitingArgument("/pr")?.title == "PR")
        check("bare pr doesn't", set.workflowAwaitingArgument("pr") == nil)
        check("/ alone doesn't", set.workflowAwaitingArgument("/") == nil)

        // Feature keywords.
        check("KeywordInput reads after the prefix",
              KeywordInput("/cal standup")?.keyword == "cal" && KeywordInput("/cal standup")?.argument == "standup")
        check("KeywordInput ignores bare words", KeywordInput("cal standup") == nil)

        // Suggestions and the command list.
        let titles = { (input: String) in set.suggestions(for: input).map(\.workflow.title) }
        check("/ lists every command in file order",
              titles("/") == ["PR", "Calendar", "Search", "Sleep"], "got \(titles("/"))")
        check("/help lists every command", titles("/help") == titles("/"), "got \(titles("/help"))")
        check("/ and /help ask for the list", set.listsAllCommands("/") && set.listsAllCommands(" /HELP "))
        check("bare help is no list", !set.listsAllCommands("help") && titles("help").isEmpty)
        check("/c suggests both cal forms", titles("/c") == ["Calendar", "Search"], "got \(titles("/c"))")
        check("bare words suggest no commands", titles("p").isEmpty && titles("c").isEmpty)
        check("completions carry the prefix",
              set.suggestions(for: "/").map(\.completion) == ["/pr ", "/cal", "/cal ", "/zz"],
              "got \(set.suggestions(for: "/").map(\.completion))")
        let withHelp = workflows(#"""
        {"workflows": [{"keywords": ["help"], "title": "Docs", "url": "https://example.com/help"}]}
        """#)
        check("a help workflow takes /help over the list",
              withHelp.map { !$0.listsAllCommands("/help") && CommandParser.parse("/help", using: $0) != nil } == true)
    }
}
