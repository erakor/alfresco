// SecurityTests.swift
//
// The checks that keep secrets and control where they belong: workflows.json
// can only use the URL schemes Config allows (never file:), and previews are
// https only, with a refused workflow left out rather than the whole file;
// the usage stats keep a fallback word only when it is near a keyword; files
// and folders the app writes are owner-only; the clipboard watcher skips
// marked copies (old markers too) and ignored apps; and a PDF over the pixel
// limit is turned down before it is drawn.
//
// Everything is written under a folder of its own, removed at the end, so
// ClipboardTests (which watches clipboard-history.json in the support folder)
// never sees any of it.

import Cocoa

@MainActor
enum SecurityTests {
    /// Kept alive until the suite exits, like ClipboardTests' stores.
    private static var stores: [ClipboardStore] = []

    static func run() {
        let root = ClipboardStore.directory.appendingPathComponent("security-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workflowSchemes(in: root)
        fallbackWords()
        permissions(in: root)
        clipboardMonitor(in: root)
        pdfSize(in: root)
        // The stores have saved (saveNow cancels their pending save), and
        // their prune ticks only delete, so nothing writes here again.
        stores.forEach { $0.saveNow() }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: workflows.json

    private static func json(_ workflows: [[String: Any]], fallback: [String: Any]? = nil) -> Data {
        var file: [String: Any] = ["workflows": workflows]
        if let fallback { file["fallback"] = fallback }
        return (try? JSONSerialization.data(withJSONObject: file)) ?? Data()
    }

    private static func workflow(_ url: String, preview: String? = nil, title: String = "T") -> [String: Any] {
        var workflow: [String: Any] = ["keywords": ["kw"], "title": title, "url": url]
        if let preview { workflow["preview"] = preview }
        return workflow
    }

    /// Whether a file with just this workflow loads it.
    private static func loads(_ url: String, preview: String? = nil) -> Bool {
        guard let set = try? JSONDecoder().decode(WorkflowSet.self, from: json([workflow(url, preview: preview)]))
        else { return false }
        return set.workflows.count == 1 && set.refused.isEmpty
    }

    private static func workflowSchemes(in root: URL) {
        check("workflows: an https url loads", loads("https://example.com/{query}"))
        check("workflows: a mailto url loads", loads("mailto:{query}@example.com"))
        check("workflows: an alfresco url loads", loads("alfresco://pomodoro/{query}"))
        check("workflows: the scheme's case doesn't matter", loads("HTTPS://example.com"))
        check("workflows: a file url is refused", !loads("file:///Applications/Calculator.app"))
        check("workflows: a file url with an argument is refused", !loads("file:///tmp/{query}"))
        check("workflows: another scheme is refused", !loads("javascript:alert(1)"))
        check("workflows: {query} can't be the scheme", !loads("{query}://example.com"))
        check("workflows: {query} can't be part of the scheme", !loads("ht{query}:x"))
        check("workflows: a url without a scheme is refused", !loads("example.com/{query}"))
        check("workflows: an https preview loads",
              loads("https://example.com/{query}", preview: "https://example.com/p/{query}"))
        check("workflows: an http preview is refused",
              !loads("https://example.com/{query}", preview: "http://example.com/p/{query}"))
        check("workflows: Workflow.scheme reads the scheme",
              Workflow.scheme(of: "Mailto:{query}") == "mailto" && Workflow.scheme(of: "x-y.z+1://a") == "x-y.z+1")
        check("workflows: Workflow.scheme has none before {query}",
              Workflow.scheme(of: "{query}:x") == nil && Workflow.scheme(of: "no-colon") == nil)
        check("workflows: the built-in fallback still loads", WorkflowSet.builtIn.fallback.takesArgument)

        // One refused workflow costs only itself.
        let mixed = json(
            [workflow("obsidian://open?vault={query}", title: "Notes"), workflow("https://example.com/{query}")],
            fallback: ["title": "Search", "url": "file:///tmp/{query}"]
        )
        let set = try? JSONDecoder().decode(WorkflowSet.self, from: mixed)
        check("workflows: a refused workflow is left out, the others load",
              set?.workflows.map(\.url) == ["https://example.com/{query}"], "\(String(describing: set?.workflows.count))")
        check("workflows: a refused fallback is replaced by the built-in one",
              set?.fallback.url == WorkflowSet.builtIn.fallback.url)
        check("workflows: each refusal is reported",
              set?.refused.count == 2 && set?.refused.first?.hasPrefix("\"Notes\": url must start with") == true,
              "\(set?.refused ?? [])")
        check("workflows: keywords only lists usable workflows", set?.keywords == ["kw"])

        let file = root.appendingPathComponent("workflows.json")
        try? mixed.write(to: file)
        let store = WorkflowStore(fileURL: file, createsMissingFile: false)
        check("workflows: the store uses the file and reports what it left out",
              store.current.workflows.count == 1 && store.loadError?.hasPrefix("left out \"Notes\"") == true,
              store.loadError ?? "no error")
    }

    // MARK: Usage stats

    private static func fallbackWords() {
        let keywords: Set<String> = ["jira", "pr", "cf", "g", "weather", "cal"]
        func word(_ input: String) -> String? { UsageStats.fallbackWordForSelfTest(in: input, keywords: keywords) }
        check("usage: a 4-letter keyword with a swapped pair of letters is kept", word("jria abc-42") == "jria")
        check("usage: a 4-letter keyword with a letter changed is kept", word("jora abc-42") == "jora")
        check("usage: a long keyword with two typos is kept", word("waethr paris") == "waethr")
        check("usage: a keyword used where it takes no argument is kept", word("cal tomorrow") == "cal")
        check("usage: a short keyword typed exactly is kept", word("pr 12") == "pr")
        check("usage: a word a typo away from a short keyword is not kept",
              word("pa taxes") == nil && word("cv template") == nil && word("or tools") == nil,
              "\(String(describing: word("pa taxes"))) \(String(describing: word("cv template")))")
        check("usage: a word a typo away from a one-letter keyword is not kept", word("a lawyer") == nil)
        check("usage: a 3-letter keyword with a typo is not kept", word("cla tomorrow") == nil)
        check("usage: a searched word is not kept", word("divorce lawyer") == nil)
        check("usage: a single word is not kept", word("jria") == nil)
    }

    // MARK: Files

    private static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    private static func octal(_ url: URL) -> String {
        "mode \(String(mode(url) ?? -1, radix: 8))"
    }

    private static func permissions(in root: URL) {
        // An earlier build's support folder: readable by others.
        let folder = root.appendingPathComponent("store", isDirectory: true)
        let images = folder.appendingPathComponent("clipboard-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: images.path)
        stores.append(ClipboardStore(directory: folder))
        check("files: the store makes its existing folder owner-only", mode(folder) == 0o700, octal(folder))
        check("files: the store makes its existing images folder owner-only", mode(images) == 0o700, octal(images))

        let file = root.appendingPathComponent("written.json")
        try? Data("{}".utf8).write(to: file, options: .atomic)
        check("files: a file is owner-only as soon as it is written (umask)", mode(file) == 0o600, octal(file))

        ClipImageFile.makePrivate(root.appendingPathComponent("missing", isDirectory: true))
        check("files: making a missing folder private creates nothing",
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }

    // MARK: Clipboard

    private static func clipboardMonitor(in root: URL) {
        check("clipboard: copies in Passwords are ignored",
              ClipboardMonitor.isIgnoredForSelfTest(ClipSource(name: "Passwords", bundleID: "com.apple.Passwords")))
        check("clipboard: copies in other apps are not",
              !ClipboardMonitor.isIgnoredForSelfTest(ClipSource(name: "TextEdit", bundleID: "com.apple.TextEdit"))
                  && !ClipboardMonitor.isIgnoredForSelfTest(ClipSource(name: nil, bundleID: nil)))

        // A pasteboard of its own, so the real clipboard is never touched.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("local.launcher.selftest.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardStore(directory: root.appendingPathComponent("monitor", isDirectory: true))
        stores.append(store)
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

        func copy(_ text: String, marker: String? = nil) {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if let marker { item.setData(Data([1]), forType: NSPasteboard.PasteboardType(marker)) }
            pasteboard.writeObjects([item])
            monitor.pollForSelfTest()
        }

        copy("hunter2", marker: "org.nspasteboard.ConcealedType")
        check("clipboard: a copy marked Concealed is not recorded", store.items.isEmpty)
        copy("hunter3", marker: "com.agilebits.onepassword")
        check("clipboard: a copy with an older password manager marker is not recorded", store.items.isEmpty)
        copy("hello")
        check("clipboard: an unmarked copy is recorded", store.items.first?.content == ClipContent.text("hello"),
              "\(store.items.count) items")
    }

    private static func pdf(width: CGFloat, height: CGFloat) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func pdfSize(in root: URL) {
        let directory = root.appendingPathComponent("pdf-images", isDirectory: true)
        let small = ClipImageFile.save(pdf(width: 200, height: 100), type: .pdf, in: directory)
        check("clipboard: a PDF is recorded at one pixel per point, whatever the screen's scale",
              small?.pixelWidth == 200 && small?.pixelHeight == 100,
              "\(String(describing: small?.pixelWidth)) x \(String(describing: small?.pixelHeight))")
        let huge = ClipImageFile.save(pdf(width: 10_000, height: 10_000), type: .pdf, in: directory)
        check("clipboard: a PDF page over the pixel limit is turned down", huge == nil)
    }
}
