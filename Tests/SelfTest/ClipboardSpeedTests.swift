// ClipboardSpeedTests.swift
//
// The clipboard work that was moved off the main thread or made to repeat
// less: the history panel's search (folded, narrowed from the previous
// query's matches only when that gives the same result as a full search),
// the text size and whitespace check on each copy, and the background
// thumbnail decoder (one decode per file, newest request first, failures
// reported and not retried until forgotten, waiting requests dropped by
// cancelPending, results of a decode started before removeAll dropped).

import Cocoa
import ImageIO

@MainActor
enum ClipboardSpeedTests {
    static func run() {
        filter()
        recordableText()
    }

    // MARK: Search

    private static func item(_ content: ClipContent) -> ClipItem {
        ClipItem(id: UUID(), copiedAt: Date(), sourceApp: nil, sourceBundleID: nil, content: content)
    }

    private static func filter() {
        let creme = item(.text("Crème brûlée recipe"))
        let cafe = item(.text("café au lait"))
        let shout = item(.text("WHERE IS IT"))
        let other = item(.text("unrelated"))
        let file = item(.files(["/Users/me/Documents/Rapport.pdf", "/Users/me/Documents/Notes.txt"]))
        let image = item(.image(ClipImage(
            hash: String(repeating: "a", count: 64), pixelWidth: 1920, pixelHeight: 1080, byteCount: 1000
        )))
        let items = [creme, cafe, shout, other, file, image]
        func ids(_ list: [ClipItem]) -> [UUID] { list.map(\.id) }
        func fresh(_ query: String, in list: [ClipItem] = items) -> [UUID] {
            var filter = ClipFilter()
            return ids(filter.items(matching: query, in: list))
        }

        check("clipboard search: an empty query lists everything", fresh("") == ids(items))
        check("clipboard search: a whitespace-only query lists everything", fresh("  ") == ids(items))
        check("clipboard search: case and accents are ignored", fresh("CREME BRULEE") == [creme.id])
        check("clipboard search: an accented query finds plain text", fresh("whère") == [shout.id])
        check("clipboard search: any copied file's path matches", fresh("notes.TXT") == [file.id])
        check("clipboard search: images match their size as shown", fresh("1920 × 1080") == [image.id])
        check("clipboard search: images match a typed size", fresh("1920x1080") == [image.id])

        // Typing on narrows from the last matches and finds what a full search does.
        var filter = ClipFilter()
        let broad = filter.items(matching: "a", in: items)
        let narrowed = filter.items(matching: "au", in: items)
        check("clipboard search: typing on only looks through the last matches",
              filter.lastSearchedCount == broad.count && broad.count < items.count,
              "looked through \(filter.lastSearchedCount) of \(items.count), last matches \(broad.count)")
        check("clipboard search: typing on finds what a full search finds", ids(narrowed) == fresh("au"),
              "got \(narrowed.count), full search \(fresh("au").count)")
        let before = filter.items(matching: "e au", in: items)
        check("clipboard search: typing before the query narrows too",
              filter.lastSearchedCount == narrowed.count && ids(before) == [cafe.id],
              "looked through \(filter.lastSearchedCount)")
        _ = filter.items(matching: "creme", in: items)
        check("clipboard search: a different query looks through everything", filter.lastSearchedCount == items.count,
              "looked through \(filter.lastSearchedCount)")

        // A copy that arrives while a search is shown is found by the next keystroke.
        _ = filter.items(matching: "zz", in: items)
        let added = item(.text("zzz top"))
        filter.historyDidChange([added] + items)
        let after = filter.items(matching: "zzz", in: [added] + items)
        check("clipboard search: after the history changes, new items are searched", ids(after) == [added.id])
        filter.forgetQuery()
        check("clipboard search: forgetQuery forgets the last query",
              ids(filter.items(matching: "lait", in: [added] + items)) == [cafe.id]
                  && filter.lastSearchedCount == items.count + 1)

        // Folded texts are made once per item: kept when the panel closes,
        // dropped with the item.
        let folded = filter.foldedCountForSelfTest
        filter.forgetQuery()
        check("clipboard search: folded texts are kept when the panel closes",
              folded == items.count + 1 && filter.foldedCountForSelfTest == folded, "\(folded) folded")
        filter.historyDidChange(items.filter { $0.id != cafe.id })
        check("clipboard search: folded texts of items gone from the history are dropped",
              filter.foldedCountForSelfTest == items.count - 1, "\(filter.foldedCountForSelfTest) folded")

        // Matches are whole characters.
        let thumbs = item(.text("great 👍🏽 work"))
        check("clipboard search: a match never splits a character",
              fresh("👍", in: [thumbs]).isEmpty && fresh("👍🏽", in: [thumbs]) == [thumbs.id])
        check("clipboard search: a flag is not matched across two flags",
              !ClipFilter.contains("🇫🇷🇺🇸", "🇷🇺") && ClipFilter.contains("🇫🇷🇺🇸", "🇺🇸"))
    }

    // MARK: Copied text

    private static func recordableText() {
        let limit = Config.clipboardMaxTextBytes
        check("clipboard text: whitespace only is skipped", !ClipboardMonitor.isRecordableForSelfTest(" \n\t\u{00A0}\u{2003} "))
        check("clipboard text: text with spaces around it is kept", ClipboardMonitor.isRecordableForSelfTest("  x \n"))
        check("clipboard text: text at the size limit is kept",
              ClipboardMonitor.isRecordableForSelfTest(String(repeating: "a", count: limit)))
        check("clipboard text: text over the size limit is skipped",
              !ClipboardMonitor.isRecordableForSelfTest(String(repeating: "a", count: limit + 1)))
        check("clipboard text: the limit counts UTF-8 bytes",
              ClipboardMonitor.isRecordableForSelfTest(String(repeating: "é", count: limit / 2))
                  && !ClipboardMonitor.isRecordableForSelfTest(String(repeating: "é", count: limit / 2 + 1)))
        check("clipboard text: oversized whitespace is skipped",
              !ClipboardMonitor.isRecordableForSelfTest(String(repeating: " ", count: limit + 1)))
        check("clipboard text: a combining mark on a space counts as text, as trimming did",
              ClipboardMonitor.isRecordableForSelfTest(" \u{301}")
                  && ClipboardMonitor.isRecordableForSelfTest("\u{3000}\u{20DD}"))
    }
}

// MARK: - Thumbnails

/// What a ThumbnailLoader reported, in order.
private final class LoadLog {
    var names: [String] = []
}

@MainActor
enum ThumbnailTests {
    static func run() async {
        let directory = ClipboardStore.directory.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wide = directory.appendingPathComponent("wide.png")
        let tall = directory.appendingPathComponent("tall.png")
        let broken = directory.appendingPathComponent("broken.png")
        try? Data("not a png".utf8).write(to: broken)
        guard writePNG(width: 2000, height: 1000, to: wide), writePNG(width: 300, height: 600, to: tall) else {
            check("thumbnails: test images written", false)
            return
        }

        let loader = ThumbnailLoader(maxPixelSize: 96, costLimit: 1024 * 1024)
        let log = LoadLog()
        loader.onLoad = { url, image in log.names.append(url.lastPathComponent + (image == nil ? " failed" : "")) }

        let first = loader.image(for: wide)
        let again = loader.image(for: wide)
        check("thumbnails: nothing is decoded on the spot", first == nil && again == nil && !loader.isIdleForSelfTest)
        await waitUntilIdle(loader)
        check("thumbnails: each file is decoded once", log.names == ["wide.png"], "loaded \(log.names)")
        let size = loader.image(for: wide)?.size
        check("thumbnails: the picture is downsampled to the size asked", size == NSSize(width: 96, height: 48),
              "size \(String(describing: size))")
        check("thumbnails: a cached picture needs no decode", loader.isIdleForSelfTest)

        // While one decodes, the newest request waiting goes next.
        loader.removeAll()
        log.names.removeAll()
        _ = loader.image(for: wide)
        _ = loader.image(for: tall)
        _ = loader.image(for: broken)
        await waitUntilIdle(loader)
        check("thumbnails: the newest request waiting is decoded first",
              log.names == ["wide.png", "broken.png failed", "tall.png"], "loaded \(log.names)")
        check("thumbnails: a file that can't be decoded is reported as failed", loader.hasFailed(broken))
        let retry = loader.image(for: broken)
        check("thumbnails: a file that can't be decoded is not tried again", retry == nil && loader.isIdleForSelfTest)
        loader.forgetFailures()
        _ = loader.image(for: broken)
        check("thumbnails: forgetFailures lets it be tried again", !loader.isIdleForSelfTest && !loader.hasFailed(broken))
        await waitUntilIdle(loader)

        // Requests no longer wanted are dropped; the running decode finishes.
        loader.removeAll()
        log.names.removeAll()
        _ = loader.image(for: wide)
        _ = loader.image(for: tall)
        loader.cancelPending()
        await waitUntilIdle(loader)
        check("thumbnails: cancelPending drops the waiting requests only",
              log.names == ["wide.png"] && loader.cachedImageForSelfTest(tall) == nil, "loaded \(log.names)")
        _ = loader.image(for: tall)
        check("thumbnails: a dropped request can be made again", !loader.isIdleForSelfTest)
        await waitUntilIdle(loader)

        loader.removeAll()
        log.names.removeAll()
        _ = loader.image(for: tall)
        loader.removeAll()
        await waitUntilIdle(loader)
        check("thumbnails: a decode started before removeAll is dropped",
              log.names.isEmpty && loader.cachedImageForSelfTest(tall) == nil, "loaded \(log.names)")
        _ = loader.image(for: broken)
        await waitUntilIdle(loader)
        loader.removeAll()
        _ = loader.image(for: broken)
        check("thumbnails: removeAll forgets failures", !loader.isIdleForSelfTest)
        await waitUntilIdle(loader)
    }

    private static func waitUntilIdle(_ loader: ThumbnailLoader) async {
        let deadline = Date().addingTimeInterval(10)
        while !loader.isIdleForSelfTest, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func writePNG(width: Int, height: Int, to url: URL) -> Bool {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
