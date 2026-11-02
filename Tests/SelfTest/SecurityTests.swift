// SecurityTests.swift
//
// The checks that keep secrets and control where they belong: workflows.json
// can only use the URL schemes Config allows (never file:), previews are
// https only, the usage stats keep a fallback word only when it is near a
// keyword, files and folders the app writes are owner-only, the clipboard
// watcher skips marked copies (old markers too) and ignored apps, and a PDF
// over the pixel limit is turned down before it is drawn.

import Cocoa

@MainActor
enum SecurityTests {
    /// Kept alive until the suite exits, like ClipboardTests' stores.
    private static var stores: [ClipboardStore] = []

    static func run() {
        workflowSchemes()
        fallbackWords()
        permissions()
        clipboardMonitor()
        pdfSize()
    }

    // MARK: workflows.json

    private static func decodes(url: String, preview: String? = nil) -> Bool {
        var workflow: [String: Any] = ["keywords": ["kw"], "title": "T", "url": url]
        if let preview { workflow["preview"] = preview }
        let json: [String: Any] = ["workflows": [workflow]]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return false }
        return (try? JSONDecoder().decode(WorkflowSet.self, from: data)) != nil
    }

    private static func workflowSchemes() {
        check("workflows: an https url loads", decodes(url: "https://example.com/{query}"))
        check("workflows: a mailto url loads", decodes(url: "mailto:{query}@example.com"))
        check("workflows: an alfresco url loads", decodes(url: "alfresco://pomodoro/{query}"))
        check("workflows: the scheme's case doesn't matter", decodes(url: "HTTPS://example.com"))
        check("workflows: a file url is refused", !decodes(url: "file:///Applications/Calculator.app"))
        check("workflows: a file url with an argument is refused", !decodes(url: "file:///tmp/{query}"))
        check("workflows: another scheme is refused", !decodes(url: "javascript:alert(1)"))
        check("workflows: {query} can't be the scheme", !decodes(url: "{query}://example.com"))
        check("workflows: {query} can't be part of the scheme", !decodes(url: "ht{query}:x"))
        check("workflows: a url without a scheme is refused", !decodes(url: "example.com/{query}"))
        check("workflows: an https preview loads",
              decodes(url: "https://example.com/{query}", preview: "https://example.com/p/{query}"))
        check("workflows: an http preview is refused",
              !decodes(url: "https://example.com/{query}", preview: "http://example.com/p/{query}"))
        check("workflows: Workflow.scheme reads the scheme",
              Workflow.scheme(of: "Mailto:{query}") == "mailto" && Workflow.scheme(of: "x-y.z+1://a") == "x-y.z+1")
        check("workflows: Workflow.scheme has none before {query}",
              Workflow.scheme(of: "{query}:x") == nil && Workflow.scheme(of: "no-colon") == nil)
        check("workflows: the built-in fallback still loads", WorkflowSet.builtIn.fallback.takesArgument)
    }

    // MARK: Usage stats

    private static func fallbackWords() {
        let keywords: Set<String> = ["jira", "pr", "weather", "cal"]
        func word(_ input: String) -> String? { UsageStats.fallbackWordForSelfTest(in: input, keywords: keywords) }
        check("usage: a keyword with a swapped pair of letters is kept", word("jria abc-42") == "jria")
        check("usage: a keyword with a letter changed is kept", word("pt 12") == "pt")
        check("usage: a long keyword with two typos is kept", word("waethr paris") == "waethr")
        check("usage: a keyword used where it takes no argument is kept", word("cal tomorrow") == "cal")
        check("usage: a searched word is not kept", word("divorce lawyer") == nil)
        check("usage: a short word two typos from a short keyword is not kept", word("is it") == nil)
        check("usage: a single word is not kept", word("jria") == nil)
    }

    // MARK: Files

    private static func mode(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    }

    private static func permissions() {
        let base = ClipboardStore.directory.appendingPathComponent("permissions", isDirectory: true)
        let folder = base.appendingPathComponent("existing", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? ClipImageFile.createPrivateDirectory(folder)
        check("files: an existing folder is made owner-only", mode(folder.path) == 0o700,
              "mode \(String(mode(folder.path) ?? -1, radix: 8))")

        let file = base.appendingPathComponent("written.json")
        try? Data("{}".utf8).write(to: file, options: .atomic)
        check("files: a file is owner-only as soon as it is written (umask)", mode(file.path) == 0o600,
              "mode \(String(mode(file.path) ?? -1, radix: 8))")
    }

    // MARK: Clipboard

    private static func clipboardMonitor() {
        check("clipboard: copies in Passwords are ignored",
              ClipboardMonitor.isIgnoredForSelfTest(ClipSource(name: "Passwords", bundleID: "com.apple.Passwords")))
        check("clipboard: copies in other apps are not",
              !ClipboardMonitor.isIgnoredForSelfTest(ClipSource(name: "TextEdit", bundleID: "com.apple.TextEdit"))
                  && !ClipboardMonitor.isIgnoredForSelfTest(ClipSource(name: nil, bundleID: nil)))

        // A pasteboard of its own, so the real clipboard is never touched.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("local.launcher.selftest.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardStore()
        stores.append(store)
        store.clear()
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

    private static func pdfSize() {
        let directory = ClipboardStore.directory.appendingPathComponent("pdf-images", isDirectory: true)
        let small = ClipImageFile.save(pdf(width: 200, height: 100), type: .pdf, in: directory)
        check("clipboard: a small PDF is recorded as an image", small != nil)
        let huge = ClipImageFile.save(pdf(width: 10_000, height: 10_000), type: .pdf, in: directory)
        check("clipboard: a PDF page over the pixel limit is turned down", huge == nil)
    }
}
