// PerfTests.swift
//
// `--self-test perf`: times the clipboard and launcher work that could cost
// the main thread, against a seeded history in the scratch folder (500 items:
// short texts, ten 200 KB texts and twenty generated 5120 × 2880 PNG
// screenshots). Prints the median and p95 of each scenario and never fails on
// a number, since CI runners are noisy; only the setup is checked. Run it with
// `PERF=1 Tests/run-self-tests.sh`.
//
// PERF_RUNS (default 20) sets the runs per scenario. PERF_ONLY=<scenario>
// runs only that one after seeding, printing PERF_READY a second before it
// starts, so a profiler (`sample <pid>`) can be attached; use a large
// PERF_RUNS for that. PERF_BIG_TEXTS (default 10) sets how many of the texts
// are 200 KB ones, up to 480 for a history near the size limit.
//
// The panels are shown on screen while it runs, and close like they always
// do when another window takes the focus: a run cut short that way is left
// out and counted as "interrupted". Restores are written to a private named
// pasteboard, never the system clipboard.

import Cocoa
import ImageIO

@available(macOS 13, *)
@MainActor
enum PerfTests {
    static let scenarios = ["load", "save", "imagesave", "open", "filter", "type", "select", "decode", "restore", "launcher"]

    private static let clock = ContinuousClock()
    private static var runs = 20
    private static var only: String?
    private static var bigTextCount = 10

    /// Width × height of the seeded screenshots (a 5K display).
    private static let screenshotSize = (width: 5120, height: 2880)
    private static let bigTextBytes = 200 * 1024
    private static let query = "projec"

    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        runs = max(1, Int(environment["PERF_RUNS"] ?? "") ?? 20)
        only = environment["PERF_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        bigTextCount = min(480, max(0, Int(environment["PERF_BIG_TEXTS"] ?? "") ?? 10))
        if let only, !scenarios.contains(only) {
            check("perf: PERF_ONLY names a scenario (\(scenarios.joined(separator: ", ")))", false, only)
            return
        }
        logMachine()

        guard let seed = await makeSeed() else { return }
        if await wants("load") { load() }
        if await wants("save") { save(seed) }
        if await wants("imagesave") { imageSave(seed) }

        let controller = ClipboardController(store: seed.store, monitor: ClipboardMonitor(store: seed.store))
        if await wants("open") { await open(controller) }
        if await wants("filter") { filter(seed) }
        if await wants("type") { await type(controller) }
        if await wants("select") { await select(controller) }
        if await wants("decode") { await decode(seed) }
        if await wants("restore") { restore(seed, controller) }
        if await wants("launcher") { await launcher() }
    }

    private static func wants(_ scenario: String) async -> Bool {
        guard let only else { return true }
        guard only == scenario else { return false }
        SelfTest.log("PERF_READY \(scenario)")
        // Time for a profiler to attach.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return true
    }

    // MARK: Seed

    private struct Seed {
        let store: ClipboardStore
        /// The twenty 5K screenshots, in history order.
        let screenshots: [ClipImage]
        /// A 2560 × 1440 image saved like a copy but not in the history:
        /// small enough (≤ 4 MP) for a restore to add a TIFF.
        let smallImage: ClipImage
        let bigText: String
        /// ClipImageFile.save of each screenshot's PNG, as a copy does it.
        let imageSaveTimes: [Duration]
    }

    private static func makeSeed() async -> Seed? {
        let started = clock.now
        let pngs = await screenshots(count: 20)
        let small = await Task.detached { Self.screenshotPNG(width: 2560, height: 1440, seed: 999) }.value
        guard pngs.count == 20, let small else {
            check("perf: test screenshots generated", false)
            return nil
        }

        let store = ClipboardStore()
        var images: [ClipImage] = []
        var saveTimes: [Duration] = []
        for png in pngs {
            var image: ClipImage?
            saveTimes.append(clock.measure { image = ClipImageFile.save(png, type: .png, in: store.imagesDirectory) })
            if let image { images.append(image) }
        }
        guard images.count == 20,
              let smallImage = ClipImageFile.save(small, type: .png, in: store.imagesDirectory)
        else {
            check("perf: test screenshots saved", false)
            return nil
        }

        // Newest first: a screenshot every 25 items from the 4th, the 200 KB
        // texts spread evenly over the other 480 places, short texts in the
        // rest; two minutes apart, so the oldest is under 17 hours old.
        var random = SplitMix64(seed: 42)
        var texts = Set<String>()
        var bigTexts: [String] = []
        var contents: [ClipContent] = []
        let textPlaces = Config.clipboardMaxItems - images.count
        var textPlace = 0
        for index in 0..<Config.clipboardMaxItems {
            if index % 25 == 3, index / 25 < images.count {
                contents.append(.image(images[index / 25]))
                continue
            }
            defer { textPlace += 1 }
            // True for bigTextCount of the textPlaces places, evenly spread
            // and half a gap in, so the save scenario's additions (which
            // push the oldest items out) never drop one.
            let place = textPlace + textPlaces / (2 * max(bigTextCount, 1))
            if (place + 1) * bigTextCount / textPlaces != place * bigTextCount / textPlaces {
                // Each 200 KB text is different, so none is merged into another.
                let text = "\(bigTexts.count) " + bigText(&random)
                bigTexts.append(text)
                contents.append(.text(text))
            } else {
                var text = shortText(&random)
                while !texts.insert(text).inserted { text = shortText(&random) }
                contents.append(.text(text))
            }
        }
        let sources = [
            ClipSource(name: "Safari", bundleID: "com.apple.Safari"),
            ClipSource(name: "Terminal", bundleID: "com.apple.Terminal"),
            ClipSource(name: "Notes", bundleID: "com.apple.Notes"),
            ClipSource(name: "Finder", bundleID: "com.apple.finder"),
            ClipSource(name: "Gone", bundleID: "local.launcher.selftest.uninstalled"),
        ]
        let now = Date()
        for (index, content) in contents.enumerated().reversed() {
            store.add(content, source: sources[index % sources.count], copiedAt: now.addingTimeInterval(-120 * Double(index)))
        }
        store.saveNow()

        let historyBytes = fileSize(ClipboardStore.directory.appendingPathComponent("clipboard-history.json"))
        check("perf: seeded history has \(Config.clipboardMaxItems) items, 20 of them screenshots",
              store.items.count == Config.clipboardMaxItems && bigTexts.count == bigTextCount,
              "\(store.items.count) items, \(bigTexts.count) big texts")
        let pngSizes = images.map(\.byteCount)
        SelfTest.log(String(
            format: "PERF seed: history file %.1f MB; screenshots %.1f to %.1f MB each; seeded in %.1f s",
            Double(historyBytes) / 1_048_576,
            Double(pngSizes.min() ?? 0) / 1_048_576, Double(pngSizes.max() ?? 0) / 1_048_576,
            milliseconds(clock.now - started) / 1000
        ))
        return Seed(store: store, screenshots: images, smallImage: smallImage, bigText: bigTexts.first ?? bigText(&random), imageSaveTimes: saveTimes)
    }

    private static let words = [
        "the", "project", "deploy", "server", "function", "return", "value", "error", "build", "release",
        "config", "update", "merge", "branch", "commit", "review", "meeting", "notes", "let", "var", "struct",
        "import", "test", "user", "data", "file", "report", "draft", "budget", "café", "résumé", "and", "for",
        "with", "https://example.com/a/path?id=42", "TODO:", "{", "}", "=", "0.5", "2026-11-02",
    ]

    private static func shortText(_ random: inout SplitMix64) -> String {
        let count = Int.random(in: 1...30, using: &random)
        return (0..<count).map { _ in
            let word = words.randomElement(using: &random) ?? ""
            return Int.random(in: 0..<12, using: &random) == 0 ? word + "\n" : word
        }.joined(separator: " ")
    }

    /// About 200 KB of log- or code-like lines.
    private static func bigText(_ random: inout SplitMix64) -> String {
        var text = ""
        text.reserveCapacity(bigTextBytes + 200)
        while text.utf8.count < bigTextBytes {
            let count = Int.random(in: 6...14, using: &random)
            text += (0..<count).map { _ in words.randomElement(using: &random) ?? "" }.joined(separator: " ") + "\n"
        }
        return text
    }

    /// `count` different screenshots, made four at a time (each takes 60 MB
    /// while drawn).
    private static func screenshots(count: Int) async -> [Data] {
        var pngs: [Data] = []
        let (width, height) = screenshotSize
        for batch in stride(from: 0, to: count, by: 4) {
            let made = await withTaskGroup(of: (Int, Data?).self) { group in
                for index in batch..<min(batch + 4, count) {
                    group.addTask {
                        (index, Self.screenshotPNG(width: width, height: height, seed: UInt64(index)))
                    }
                }
                var results: [(Int, Data?)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            pngs += made
        }
        return pngs
    }

    /// A screenshot-like PNG: a desktop, windows of text-like lines and a
    /// photo (noise, which compresses about as badly as a real one), so the
    /// file is a few MB like a real 5K screenshot rather than a few KB.
    nonisolated private static func screenshotPNG(width: Int, height: Int, seed: UInt64) -> Data? {
        var random = SplitMix64(seed: seed)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.30, green: 0.45, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for _ in 0..<5 {
            let windowWidth = Int.random(in: width / 4...width / 2, using: &random)
            let windowHeight = Int.random(in: height / 4...height * 2 / 3, using: &random)
            let x = Int.random(in: 0...(width - windowWidth), using: &random)
            let y = Int.random(in: 0...(height - windowHeight), using: &random)
            context.setFillColor(CGColor(gray: 0.98, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: windowWidth, height: windowHeight))
            context.setFillColor(CGColor(gray: 0.85, alpha: 1))
            context.fill(CGRect(x: x, y: y + windowHeight - 56, width: windowWidth, height: 56))
            var lineY = y + windowHeight - 100
            while lineY > y + 30 {
                var wordX = x + 30
                while wordX < x + windowWidth - 120 {
                    let wordWidth = Int.random(in: 14...90, using: &random)
                    let shade = CGFloat(Int.random(in: 0...40, using: &random)) / 100
                    context.setFillColor(CGColor(red: shade, green: shade, blue: shade + 0.1, alpha: 1))
                    context.fill(CGRect(x: wordX, y: lineY, width: wordWidth, height: 14))
                    wordX += wordWidth + 9
                }
                lineY -= 30
            }
        }

        // The photo: a quarter of the width and height.
        if let base = context.data {
            let bytesPerRow = context.bytesPerRow
            let photoWidth = width / 4
            let photoHeight = height / 4
            let left = Int.random(in: 0...(width - photoWidth), using: &random)
            let top = Int.random(in: 0...(height - photoHeight), using: &random)
            for row in top..<(top + photoHeight) {
                let pixels = base.advanced(by: row * bytesPerRow + left * 4).assumingMemoryBound(to: UInt32.self)
                for column in 0..<photoWidth {
                    pixels[column] = UInt32(truncatingIfNeeded: random.next()) | 0xFF00_0000
                }
            }
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Clipboard store

    private static func load() {
        var samples: [Duration] = []
        var counts = Set<Int>()
        for _ in 0..<runs {
            var store: ClipboardStore?
            samples.append(clock.measure { store = ClipboardStore() })
            counts.insert(store?.items.count ?? 0)
            // Its prune timer would keep it (and the whole history) alive.
            store?.stopTimersForSelfTest()
        }
        report("store load at launch (ClipboardStore.init)", samples, .main)
        check("perf: every load read the whole history", counts == [Config.clipboardMaxItems], "\(counts)")
    }

    /// Each add pushes the oldest item (a text) out; the seeded history is put
    /// back after each run, so any PERF_RUNS leaves the screenshots in place.
    private static func save(_ seed: Seed) {
        let seeded = seed.store.items
        var adds: [Duration] = []
        var saves: [Duration] = []
        for run in 0..<runs {
            let content = ClipContent.text("perf add \(run): deploy the project")
            adds.append(clock.measure { seed.store.add(content, source: ClipSource(name: nil, bundleID: nil)) })
            saves.append(clock.measure { seed.store.saveNow() })
            seed.store.replaceItemsForSelfTest(seeded)
        }
        seed.store.saveNow()
        check("perf: the save scenario left every screenshot in place",
              seed.screenshots.allSatisfy { FileManager.default.fileExists(atPath: seed.store.imageURL(for: $0).path) })
        report("store.add, one text into 500 items", adds, .main)
        report("saveNow after one add", saves, .main)
    }

    private static func imageSave(_ seed: Seed) {
        report("ClipImageFile.save, 5K PNG copied", seed.imageSaveTimes, .background)
        // A copy that arrives as TIFF (some apps put only TIFF on the
        // clipboard) is converted to PNG first.
        guard let png = seed.store.imageData(for: seed.screenshots[0]),
              let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation
        else {
            check("perf: TIFF test copy made", false)
            return
        }
        let directory = ClipboardStore.directory.appendingPathComponent("perf-tiff", isDirectory: true)
        let count = min(runs, 5)
        var saved = 0
        let samples = (0..<count).map { _ in
            clock.measure { if ClipImageFile.save(tiff, type: .tiff, in: directory) != nil { saved += 1 } }
        }
        report("ClipImageFile.save, 5K TIFF copied (to PNG)", samples, .background)
        check("perf: every TIFF copy was saved as a PNG", saved == count, "\(saved) of \(count)")
    }

    // MARK: Clipboard panel

    private static func open(_ controller: ClipboardController) async {
        var samples: [Duration] = []
        // One more run than asked: the first opening is reported apart.
        for _ in 0...runs {
            samples.append(clock.measure {
                controller.show()
                draw(controller.panel)
            })
            await hide(controller)
            if samples.count == 1 {
                // Lets the first opening's thumbnails finish, as they would
                // before a later opening.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        report("clipboard panel open, first", Array(samples.prefix(1)), .main)
        report("clipboard panel open, later", Array(samples.dropFirst()), .main)
    }

    /// The search alone, the first time after launch (nothing folded yet).
    private static func filter(_ seed: Seed) {
        var samples: [Duration] = []
        var matches = 0
        for _ in 0..<runs {
            var filter = ClipFilter()
            samples.append(clock.measure { matches = filter.items(matching: String(query.prefix(1)), in: seed.store.items).count })
        }
        report("search, first keystroke since launch (folds all)", samples, .main, note: "\(matches) matches")
    }

    private static func type(_ controller: ClipboardController) async {
        var first: [Duration] = []
        var later: [Duration] = []
        var whole: [Duration] = []
        var matches = 0
        var interrupted = 0
        while whole.count < runs, interrupted < runs {
            controller.show()
            draw(controller.panel)
            let keystrokes = (1...query.count).map { length in
                clock.measure {
                    controller.typeForSelfTest(String(query.prefix(length)))
                    draw(controller.panel)
                }
            }
            if controller.panel.isVisible {
                first.append(keystrokes[0])
                later += keystrokes.dropFirst()
                whole.append(keystrokes.reduce(.zero, +))
                matches = controller.visibleCountForSelfTest
            } else {
                interrupted += 1
            }
            await hide(controller)
        }
        report("typing \"\(query)\": keystroke 1 (all 500 items)", first, .main)
        report("typing \"\(query)\": keystrokes 2-6 (narrowed)", later, .main)
        report("typing \"\(query)\": all 6 keystrokes", whole, .main,
               note: "\(matches) matches" + interruptedNote(interrupted))
    }

    private static func select(_ controller: ClipboardController) async {
        var sync: [Duration] = []
        var shown: [Duration] = []
        var timedOut = 0
        var interrupted = 0
        controller.show()
        draw(controller.panel)
        var rows = controller.imageRowsForSelfTest
        while sync.count < runs, interrupted < runs {
            if rows.isEmpty {
                // Every picture is cached now: start over with an empty cache.
                await hide(controller)
                controller.show()
                draw(controller.panel)
                rows = controller.imageRowsForSelfTest
                if rows.isEmpty { break }
            }
            let row = rows.removeFirst()
            let start = clock.now
            controller.selectForSelfTest(row: row)
            draw(controller.panel)
            let selected = clock.now - start
            // A hidden panel drops the picture it was waiting for.
            let finished = await wait(timeout: 3) {
                !controller.isAwaitingPreviewForSelfTest || !controller.panel.isVisible
            }
            guard controller.panel.isVisible else {
                interrupted += 1
                controller.show()
                draw(controller.panel)
                continue
            }
            sync.append(selected)
            if finished {
                draw(controller.panel)
                shown.append(clock.now - start)
            } else {
                timedOut += 1
            }
        }
        await hide(controller)
        report("select an image row (preview), main thread", sync, .main, note: interruptedNote(interrupted))
        report("select an image row, until the picture shows", shown, .background,
               note: (timedOut > 0 ? "\(timedOut) timed out" : "") + interruptedNote(interrupted))
    }

    /// The thumbnail loaders alone: one decode each, from request to result.
    private static func decode(_ seed: Seed) async {
        for size in [96, 1200] {
            let loader = ThumbnailLoader(maxPixelSize: size, costLimit: 512 * 1024 * 1024)
            var samples: [Duration] = []
            var failed = 0
            var timedOut = 0
            for run in 0..<runs {
                if run > 0, run % seed.screenshots.count == 0 { loader.removeAll() }
                let url = seed.store.imageURL(for: seed.screenshots[run % seed.screenshots.count])
                let start = clock.now
                _ = loader.image(for: url)
                guard await wait(until: { loader.isIdleForSelfTest }) else {
                    timedOut += 1
                    continue
                }
                let elapsed = clock.now - start
                // A file that didn't decode would time a failure, not a decode.
                if loader.cachedImageForSelfTest(url) != nil { samples.append(elapsed) } else { failed += 1 }
            }
            report("thumbnail decode, 5K PNG to \(size) px", samples, .background,
                   note: timedOut > 0 ? "\(timedOut) timed out" : "")
            check("perf: every \(size) px decode gave a picture", failed == 0 && timedOut == 0,
                  "\(failed) failed, \(timedOut) timed out")
        }
    }

    private static func restore(_ seed: Seed, _ controller: ClipboardController) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("local.launcher.selftest.perf"))
        defer { pasteboard.releaseGlobally() }
        func measure(_ name: String, _ content: (Int) -> ClipContent) {
            var written = true
            let samples = (0..<runs).map { run in
                clock.measure { written = controller.writeForSelfTest(content(run), to: pasteboard) && written }
            }
            report(name, samples, .main)
            check("perf: \(name) wrote to the pasteboard", written)
        }
        measure("restore a 5K screenshot (PNG only)") { .image(seed.screenshots[$0 % seed.screenshots.count]) }
        measure("restore a 2560x1440 image (PNG + TIFF)") { _ in .image(seed.smallImage) }
        measure("restore a 200 KB text") { _ in .text(seed.bigText) }
    }

    // MARK: Launcher

    private static func launcher() async {
        let launcher = LauncherController(store: WorkflowStore(), internalURLHandler: { _ in false })
        let scanned = await wait(timeout: 30) { launcher.appCountForSelfTest > 0 }
        check("perf: the launcher found installed apps", scanned, "no scan finished in 30 s")
        guard scanned else { return }
        SelfTest.log("PERF launcher: \(launcher.appCountForSelfTest) apps found")

        launcher.show()
        draw(launcher.panel)
        // Typed one character at a time, as real typing goes; the timings
        // after 1, 3 and 10 characters are kept.
        for (typed, label) in [("system set", "app found"), ("qzxwvkjhgf", "no app found")] {
            var samples: [Int: [Duration]] = [1: [], 3: [], 10: []]
            var matchCalls: [Int: Int] = [:]
            var interrupted = 0
            var done = 0
            while done < runs, interrupted < runs {
                if !launcher.panel.isVisible {
                    launcher.show()
                    draw(launcher.panel)
                }
                launcher.typeForSelfTest("")
                var keystrokes: [Int: Duration] = [:]
                for length in 1...typed.count {
                    let calls = AppIndex.matchCallsForSelfTest
                    let keystroke = clock.measure {
                        launcher.typeForSelfTest(String(typed.prefix(length)))
                        draw(launcher.panel)
                    }
                    if samples[length] != nil {
                        keystrokes[length] = keystroke
                        matchCalls[length] = AppIndex.matchCallsForSelfTest - calls
                    }
                }
                guard launcher.panel.isVisible else {
                    interrupted += 1
                    continue
                }
                for (length, keystroke) in keystrokes { samples[length]?.append(keystroke) }
                done += 1
            }
            for length in [1, 3, 10] {
                report("launcher inputDidChange, \(length) char\(length == 1 ? "" : "s") (\(label))",
                       samples[length] ?? [], .main,
                       note: "apps.match ×\(matchCalls[length] ?? 0)" + interruptedNote(interrupted))
            }
        }
        launcher.typeForSelfTest("")
        await hide(launcher)
    }

    // MARK: Helpers

    private enum Thread: String {
        case main, background
    }

    /// Lays out and draws now what would otherwise wait for the run loop.
    private static func draw(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        panel.displayIfNeeded()
    }

    private static func hide(_ controller: FloatingPanelController) async {
        controller.hide()
        _ = await wait(timeout: 2) { !controller.panel.isVisible }
    }

    /// Polls every millisecond; false after `timeout` seconds.
    private static func wait(timeout: Int = 10, until condition: () -> Bool) async -> Bool {
        let deadline = clock.now + .seconds(timeout)
        while !condition() {
            if clock.now > deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }

    private static func interruptedNote(_ count: Int) -> String {
        count > 0 ? "  \(count) interrupted (panel lost focus)" : ""
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }

    /// One line: median and p95 (nearest rank) in milliseconds.
    private static func report(_ name: String, _ samples: [Duration], _ thread: Thread, note: String = "") {
        let note = note.trimmingCharacters(in: .whitespaces)
        guard !samples.isEmpty else {
            SelfTest.log("PERF \(name): no samples")
            return
        }
        let sorted = samples.map(milliseconds).sorted()
        let count = sorted.count
        let median = count % 2 == 1 ? sorted[count / 2] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        let p95 = sorted[min(count - 1, Int((0.95 * Double(count)).rounded(.up)) - 1)]
        let padded = name.padding(toLength: max(52, name.count), withPad: " ", startingAt: 0)
        SelfTest.log(String(format: "PERF %@ median %9.3f ms  p95 %9.3f ms  n=%-3d %@%@",
                            padded, median, p95, count, "[\(thread.rawValue)]", note.isEmpty ? "" : "  \(note)"))
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func logMachine() {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let cpu = brand.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let info = ProcessInfo.processInfo
        SelfTest.log(String(
            format: "PERF machine: %@, %d cores, %.0f GB; %@; %d runs per scenario",
            cpu, info.processorCount, Double(info.physicalMemory) / 1_073_741_824,
            info.operatingSystemVersionString, runs
        ))
    }
}

/// A seeded generator, so every run builds the same history.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
