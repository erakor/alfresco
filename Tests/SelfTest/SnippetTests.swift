// SnippetTests.swift
//
// Pinned clips as snippets: the name rules, naming in the store (it pins,
// a name is unique, unpinning drops it, it survives a save and reload, an
// older file reads without one), finding a snippet from what is typed after
// `/snip`, the one-line previews, the alfresco://snippet URL, and the list
// and hint the launcher shows while `/snip` is typed.

import Foundation

@MainActor
enum SnippetTests {
    private static var stores: [ClipboardStore] = []

    static func run() {
        names()
        store()
        finding()
        commands()
        launcher()
    }

    private static func names() {
        check("snippets: a name is trimmed and lowercased", SnippetName.normalize("  Sig ") == "sig")
        check("snippets: accents and dashes are fine", SnippetName.normalize("adresse-pro_2") == "adresse-pro_2"
              && SnippetName.normalize("Été") == "été")
        for bad in ["", "   ", "two words", "a/b", "a?b", "a#b", "50%", String(repeating: "x", count: SnippetName.maxLength + 1)] {
            check("snippets: \"\(bad)\" is not a name", SnippetName.normalize(bad) == nil)
        }
        check("snippets: maxLength is allowed",
              SnippetName.normalize(String(repeating: "x", count: SnippetName.maxLength)) != nil)
    }

    private static func store() {
        let directory = ClipboardStore.directory.appendingPathComponent("snippets", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ClipboardStore(directory: directory)
        stores.append(store)
        let source = ClipSource(name: nil, bundleID: nil)
        func item(_ text: String) -> ClipItem? { store.items.first { $0.content == .text(text) } }

        store.add(.text("Best regards,\nAmaury"), source: source)
        store.add(.text("FR76 1234"), source: source)
        store.add(.text("loose"), source: source)

        guard let signature = item("Best regards,\nAmaury")?.id, let iban = item("FR76 1234")?.id,
              let loose = item("loose")?.id else {
            check("snippets: the test clips are recorded", false)
            return
        }
        check("snippets: naming an unpinned clip pins it",
              store.setSnippetName(id: signature, " Sig ") && item("Best regards,\nAmaury")?.pinned == true)
        check("snippets: the name is stored normalized", item("Best regards,\nAmaury")?.snippetName == "sig")
        check("snippets: a bad name changes nothing",
              !store.setSnippetName(id: iban, "my iban") && item("FR76 1234")?.pinned == false
                  && item("FR76 1234")?.snippetName == nil)
        store.setSnippetName(id: iban, "iban")
        store.setSnippetName(id: loose, "sig")
        check("snippets: a name taken by another clip moves to the new one",
              item("loose")?.snippetName == "sig" && item("Best regards,\nAmaury")?.snippetName == nil,
              "\(String(describing: item("loose")?.snippetName)) / \(String(describing: item("Best regards,\nAmaury")?.snippetName))")
        check("snippets: the clip that lost it stays pinned", item("Best regards,\nAmaury")?.pinned == true)
        store.setSnippetName(id: signature, "sig")
        store.setSnippetName(id: loose, "")
        check("snippets: a blank name removes it and keeps the pin",
              item("loose")?.snippetName == nil && item("loose")?.pinned == true)
        store.setPinned(id: iban, false)
        check("snippets: unpinning drops the name", item("FR76 1234")?.snippetName == nil)
        store.setSnippetName(id: iban, "iban")
        check("snippets: a gone clip can't be named", !store.setSnippetName(id: UUID(), "x"))

        store.clear()
        check("snippets: Clear keeps them", item("FR76 1234")?.snippetName == "iban")

        store.saveNow()
        let reloaded = ClipboardStore(directory: directory)
        stores.append(reloaded)
        let names = Set(reloaded.items.compactMap(\.snippetName))
        check("snippets: names survive a save and reload", names == ["sig", "iban"], "\(names)")

        // Hand-edited: a name on an unpinned clip, a bad name, two clips with one name.
        let written = """
        {"version":1,"items":[
        {"id":"\(UUID().uuidString)","copiedAt":"2026-11-03T10:00:00Z","content":{"kind":"text","text":"a"},"pinned":true,"snippetName":"Dup"},
        {"id":"\(UUID().uuidString)","copiedAt":"2026-11-03T10:00:00Z","content":{"kind":"text","text":"b"},"pinned":true,"snippetName":"dup"},
        {"id":"\(UUID().uuidString)","copiedAt":"2026-11-03T10:00:00Z","content":{"kind":"text","text":"c"},"pinned":true,"snippetName":"two words"},
        {"id":"\(UUID().uuidString)","copiedAt":"2099-11-03T10:00:00Z","content":{"kind":"text","text":"d"},"snippetName":"free"}
        ]}
        """
        let edited = ClipboardStore.directory.appendingPathComponent("snippets-edited", isDirectory: true)
        try? FileManager.default.createDirectory(at: edited, withIntermediateDirectories: true)
        try? Data(written.utf8).write(to: edited.appendingPathComponent("clipboard-history.json"))
        let handEdited = ClipboardStore(directory: edited)
        stores.append(handEdited)
        let read = handEdited.items.map { item -> String in
            guard case .text(let text) = item.content else { return "?" }
            return "\(text):\(item.snippetName ?? "-")"
        }
        check("snippets: a hand-edited file keeps one of each name, usable names, pinned clips only",
              read == ["a:dup", "b:-", "c:-", "d:-"], "\(read)")

        let oldFormat = """
        {"version":1,"items":[{"id":"\(UUID().uuidString)","copiedAt":"2026-11-03T10:00:00Z","content":{"kind":"text","text":"x"},"pinned":true}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try? decoder.decode(History.self, from: Data(oldFormat.utf8))
        check("snippets: a clip without the key has no name",
              legacy?.items.first.map { $0.pinned && $0.snippetName == nil } == true)
    }

    private struct History: Decodable {
        let items: [ClipItem]
    }

    private static func snippet(_ name: String, _ content: ClipContent) -> ClipItem {
        ClipItem(id: UUID(), copiedAt: Date(), sourceApp: nil, sourceBundleID: nil, content: content,
                 pinned: true, snippetName: name)
    }

    private static func finding() {
        let items = [
            snippet("sig", .text("Best regards")),
            snippet("sign", .text("Signed")),
            snippet("iban", .text("FR76")),
            ClipItem(id: UUID(), copiedAt: Date(), sourceApp: nil, sourceBundleID: nil, content: .text("not a snippet")),
        ]
        func names(_ found: [ClipItem]) -> [String] { found.compactMap(\.snippetName) }
        func search(_ typed: String) -> SnippetSearch { SnippetSearch(typed: typed, items: items) }
        check("snippets: all, by name", names(search("").found) == ["iban", "sig", "sign"])
        check("snippets: matches by prefix, the exact one first", names(search(" SIG ").found) == ["sig", "sign"])
        check("snippets: an exact name resolves even when others start with it",
              search("sig").resolved?.snippetName == "sig")
        check("snippets: the only prefix match resolves", search("ib").resolved?.snippetName == "iban")
        check("snippets: an ambiguous prefix doesn't", search("si").resolved == nil)
        check("snippets: neither do an unknown name and an empty one",
              search("x").resolved == nil && search("").resolved == nil)
        check("snippets: hint for a match", search("ib").hint == "↩ Paste iban")
        check("snippets: hint for several", search("si").hint == "2 snippets start with si", search("si").hint)
        check("snippets: hint for none", search("Zz").hint == "No snippet named zz")

        check("snippets: a text's summary is on one line",
              ClipContent.text("\n  Hello  \nworld").summary == "Hello world")
        let image = ClipImage(hash: String(repeating: "a", count: 64), pixelWidth: 4, pixelHeight: 3, byteCount: 1)
        check("snippets: an image's summary is its size", ClipContent.image(image).summary == "Image: 4 × 3")
        check("snippets: files' summary names them",
              ClipContent.files(["/a/x.pdf", "/a/y.pdf"]).summary == "2 files: x.pdf, y.pdf")

        let content = SnippetsViewContent(search("si"))
        check("snippets: the list shows the matches, none highlighted while ambiguous",
              content.rows.map(\.name) == ["sig", "sign"] && !content.rows.contains(where: \.highlighted)
                  && content.footer == nil)
        let exact = SnippetsViewContent(search("sig"))
        check("snippets: the one Enter pastes is highlighted", exact.rows.first?.highlighted == true
              && exact.rows.dropFirst().allSatisfy { !$0.highlighted })
        check("snippets: nothing matching says so",
              SnippetsViewContent(search("q")).footer == "No snippet starts with q")
        check("snippets: no snippets at all says how to make one",
              SnippetsViewContent(SnippetSearch(typed: "", items: [])).footer?.contains("⌘S") == true)
        let many = (0..<(SnippetsViewContent.maxRows + 2)).map { snippet("s\($0)", .text("\($0)")) }
        let capped = SnippetsViewContent(SnippetSearch(typed: "", items: many))
        check("snippets: the list is capped and counts the rest",
              capped.rows.count == SnippetsViewContent.maxRows && capped.footer == "2 more", capped.footer ?? "nil")
    }

    private static func commands() {
        check("snippets: the name in the URL", URL(string: "alfresco://snippet/Sig").flatMap(SnippetCommand.name) == "sig")
        check("snippets: an accented name comes back from the URL",
              URL(string: "alfresco://snippet/%C3%A9t%C3%A9").flatMap(SnippetCommand.name) == "été")
        check("snippets: no name, no snippet", URL(string: "alfresco://snippet/").flatMap(SnippetCommand.name) == nil)
        check("snippets: another feature isn't one", URL(string: "alfresco://stats/sig").flatMap(SnippetCommand.name) == nil)
        check("snippets: the workflow template is recognized",
              SnippetCommand.isSnippetTemplate("alfresco://snippet/{query}")
                  && !SnippetCommand.isSnippetTemplate("alfresco://pomodoro/{query}")
                  && !SnippetCommand.isSnippetTemplate("https://snippet/{query}"))
    }

    /// The launcher with the repo's `/snip` workflow: the list and the hint.
    private static func launcher() {
        let json = """
        {"workflows": [
          {"keywords": ["snip"], "title": "Paste snippet", "description": "Paste a named pinned clip",
           "url": "alfresco://snippet/{query}"}
        ]}
        """
        guard Config.commandPrefix == "/" else {
            check("snippets: the shipped prefix is /", false)
            return
        }
        let url = SelfTest.scratchFile("snippet-workflows")
        try? Data(json.utf8).write(to: url)
        let workflows = WorkflowStore(fileURL: url, createsMissingFile: false)
        let items = [snippet("sig", .text("Best regards")), snippet("iban", .text("FR76"))]
        let controller = LauncherController(store: workflows, snippets: { items }, internalURLHandler: { _ in true })

        controller.typeForSelfTest("/snip")
        check("snippets: /snip alone lists them all",
              controller.snippetsForSelfTest?.rows.map(\.name) == ["iban", "sig"])
        check("snippets: /snip alone keeps the workflow's help", controller.hintForSelfTest == "Paste a named pinned clip",
              controller.hintForSelfTest)
        controller.typeForSelfTest("/snip si")
        check("snippets: a prefix narrows the list", controller.snippetsForSelfTest?.rows.map(\.name) == ["sig"])
        check("snippets: the hint says what Enter pastes", controller.hintForSelfTest == "↩ Paste sig",
              controller.hintForSelfTest)
        controller.typeForSelfTest("/snip nope")
        check("snippets: an unknown name says so", controller.hintForSelfTest == "No snippet named nope",
              controller.hintForSelfTest)
        for other in ["/sni", "/", "", "snip sig"] {
            controller.typeForSelfTest(other)
            check("snippets: \"\(other)\" doesn't show the list", controller.snippetsForSelfTest == nil)
        }

        if let command = CommandParser.parse("/snip Sig", using: workflows.current) {
            check("snippets: /snip Sig runs alfresco://snippet/Sig, read back as sig",
                  SnippetCommand.name(of: command.url) == "sig", command.url.absoluteString)
        } else {
            check("snippets: /snip Sig parses", false)
        }
    }
}
