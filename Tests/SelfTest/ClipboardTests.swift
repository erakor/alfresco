// ClipboardTests.swift
//
// The clipboard history file: a damaged one is set aside, never over an
// earlier set-aside file, and never overwritten when it can't be moved.
// Set-aside files are deleted once past the retention period (counted from
// when they were set aside), and the history is excluded from backups.
// Pinned items stay on top, outlive the retention period, clipboardMaxItems
// and Clear, keep their pin across a save and reload, and aren't duplicated
// by copying their content again.

import Foundation

@MainActor
enum ClipboardTests {
    private static var stores: [ClipboardStore] = []

    static func run() {
        let file = ClipboardStore.directory.appendingPathComponent("clipboard-history.json")
        let base = file.deletingPathExtension()
        func backup(_ suffix: String) -> URL { base.appendingPathExtension(suffix).appendingPathExtension("json") }

        let first = Data("{not json".utf8)
        try? first.write(to: file)
        stores.append(ClipboardStore())
        check("clipboard: a damaged history is set aside as .unreadable.json",
              (try? Data(contentsOf: backup("unreadable"))) == first)

        let second = Data("{also not json".utf8)
        try? second.write(to: file)
        stores.append(ClipboardStore())
        check("clipboard: the first set-aside file is kept", (try? Data(contentsOf: backup("unreadable"))) == first)
        check("clipboard: the second goes to .unreadable-2.json",
              (try? Data(contentsOf: backup("unreadable-2"))) == second)

        // Every name taken: the damaged history stays, and saving skips it.
        for number in 3...SetAsideFile.maxFiles {
            try? Data("old".utf8).write(to: backup("unreadable-\(number)"))
        }
        let third = Data("{still not json".utf8)
        try? third.write(to: file)
        let blocked = ClipboardStore()
        stores.append(blocked)
        blocked.saveNow()
        check("clipboard: with no set-aside name free, the damaged history is not overwritten",
              (try? Data(contentsOf: file)) == third)

        // A set-aside file past the retention period is deleted at launch.
        let longAgo = Date().addingTimeInterval(-Config.clipboardRetention - 24 * 60 * 60)
        func age(_ url: URL) {
            try? FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)
        }
        age(backup("unreadable-50"))
        stores.append(ClipboardStore())
        check("clipboard: a set-aside file past the retention period is deleted",
              !FileManager.default.fileExists(atPath: backup("unreadable-50").path))
        check("clipboard: a recent set-aside file is kept",
              FileManager.default.fileExists(atPath: backup("unreadable-49").path))

        // A history last saved long ago is set aside with a fresh date, so it
        // isn't deleted by the same launch.
        age(file)
        let recovered = ClipboardStore()
        stores.append(recovered)
        check("clipboard: an old damaged history is set aside and kept",
              (try? Data(contentsOf: backup("unreadable-50"))) == third)

        recovered.saveNow()
        let excluded = (try? file.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup
        check("clipboard: the saved history is excluded from backups", excluded == true)

        pins()
    }

    private static func pins() {
        let directory = ClipboardStore.directory.appendingPathComponent("pins", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ClipboardStore(directory: directory)
        stores.append(store)
        let source = ClipSource(name: nil, bundleID: nil)
        func texts() -> [String] {
            store.items.map { item in
                if case .text(let text) = item.content { return text }
                return "?"
            }
        }
        func id(_ text: String) -> UUID? {
            store.items.first { $0.content == .text(text) }?.id
        }

        let longAgo = Date().addingTimeInterval(-Config.clipboardRetention - 60 * 60)
        store.add(.text("old"), source: source, copiedAt: longAgo)
        store.add(.text("a"), source: source)
        store.add(.text("b"), source: source)
        check("clipboard pins: setPinned succeeds", id("old").map { store.setPinned(id: $0, true) } == true)
        check("clipboard pins: a pinned item goes to the top", texts() == ["old", "b", "a"], "\(texts())")
        store.expireOldItems()
        check("clipboard pins: a pinned item outlives the retention period", id("old") != nil)

        if let found = id("a") { store.setPinned(id: found, true) }
        check("clipboard pins: the latest pin is on top", texts() == ["a", "old", "b"], "\(texts())")
        check("clipboard pins: pinnedCount", store.pinnedCount == 2)

        store.add(.text("c"), source: source)
        check("clipboard pins: a new copy goes under the pinned items", texts() == ["a", "old", "c", "b"], "\(texts())")

        store.add(.text("old"), source: source)
        check("clipboard pins: copying a pinned item's content again keeps one pinned item in place",
              texts() == ["a", "old", "c", "b"] && store.items[1].pinned, "\(texts())")
        check("clipboard pins: copying a pinned item's content again refreshes its date",
              store.items[1].copiedAt > Date().addingTimeInterval(-60))

        if let found = id("b") { store.promote(id: found) }
        check("clipboard pins: a picked unpinned item goes under the pinned ones", texts() == ["a", "old", "b", "c"], "\(texts())")
        if let found = id("old") { store.promote(id: found) }
        check("clipboard pins: a picked pinned item keeps its place", texts() == ["a", "old", "b", "c"], "\(texts())")

        store.saveNow()
        let reloaded = ClipboardStore(directory: directory)
        stores.append(reloaded)
        check("clipboard pins: pins survive a save and reload",
              reloaded.items.map(\.pinned) == [true, true, false, false])

        for number in 0..<Config.clipboardMaxItems {
            store.add(.text("filler \(number)"), source: source)
        }
        check("clipboard pins: clipboardMaxItems doesn't drop pinned items",
              id("a") != nil && id("old") != nil && store.items.count == Config.clipboardMaxItems + 2)

        store.clear()
        check("clipboard pins: Clear keeps only the pinned items", texts() == ["a", "old"], "\(texts())")

        // Copied long ago and never again, so only setPinned can give it a
        // fresh date.
        store.add(.text("stale"), source: source, copiedAt: longAgo)
        if let found = id("stale") {
            store.setPinned(id: found, true)
            store.setPinned(id: found, false)
        }
        store.expireOldItems()
        check("clipboard pins: an unpinned item gets a fresh retention period",
              texts() == ["a", "old", "stale"] && !store.items[2].pinned, "\(texts())")

        for number in 0..<Config.clipboardMaxPinnedItems {
            store.add(.text("pin \(number)"), source: source)
            if let found = id("pin \(number)") { store.setPinned(id: found, true) }
        }
        check("clipboard pins: no more than clipboardMaxPinnedItems",
              store.pinnedCount == Config.clipboardMaxPinnedItems
                  && id("stale").map { store.setPinned(id: $0, true) } == false)

        pinnedImages()

        // A history written by an older build has no "pinned" key.
        let oldFormat = """
        {"version":1,"items":[{"id":"\(UUID().uuidString)","copiedAt":"2026-11-03T10:00:00Z","content":{"kind":"text","text":"x"}}]}
        """
        let legacy = try? JSONDecoder.iso8601.decode(LegacyHistory.self, from: Data(oldFormat.utf8))
        check("clipboard pins: an item without the key reads as unpinned", legacy?.items.first?.pinned == false)
    }

    private struct LegacyHistory: Decodable {
        let items: [ClipItem]
    }

    private struct WrittenHistory: Encodable {
        let version = 1
        let items: [ClipItem]
    }

    /// A pinned image's file outlives the retention period: launch gives it
    /// a fresh date so removeStaleImages keeps it, while an unpinned one's
    /// goes. And no more than clipboardMaxPinnedImages images can be pinned.
    private static func pinnedImages() {
        let directory = ClipboardStore.directory.appendingPathComponent("pinned-images", isDirectory: true)
        let images = directory.appendingPathComponent("clipboard-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let longAgo = Date().addingTimeInterval(-Config.clipboardRetention - 3 * 60 * 60)
        func image(_ digit: Character) -> ClipImage {
            ClipImage(hash: String(repeating: digit, count: 64), pixelWidth: 10, pixelHeight: 10, byteCount: 4)
        }
        func file(_ clip: ClipImage) -> URL { images.appendingPathComponent(clip.fileName) }
        func item(_ clip: ClipImage, pinned: Bool) -> ClipItem {
            ClipItem(id: UUID(), copiedAt: longAgo, sourceApp: nil, sourceBundleID: nil, content: .image(clip), pinned: pinned)
        }
        let pinned = image("1")
        let unpinned = image("2")
        for clip in [pinned, unpinned] {
            try? Data("png".utf8).write(to: file(clip))
            try? FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: file(clip).path)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let history = WrittenHistory(items: [item(pinned, pinned: true), item(unpinned, pinned: false)])
        try? encoder.encode(history).write(to: directory.appendingPathComponent("clipboard-history.json"))

        let store = ClipboardStore(directory: directory)
        stores.append(store)
        let modified = (try? file(pinned).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        check("clipboard pins: a pinned image's file is kept at launch",
              FileManager.default.fileExists(atPath: file(pinned).path))
        check("clipboard pins: and gets a fresh date", (modified ?? longAgo) > Date().addingTimeInterval(-60))
        check("clipboard pins: an old unpinned image and its file are removed",
              store.items.count == 1 && !FileManager.default.fileExists(atPath: file(unpinned).path))

        let digits = Array("3456789abcdef")
        for digit in digits.prefix(Config.clipboardMaxPinnedImages) {
            let clip = image(digit)
            try? Data("png".utf8).write(to: file(clip))
            store.add(.image(clip), source: ClipSource(name: nil, bundleID: nil))
            if let found = store.items.first(where: { $0.content == .image(clip) }) {
                store.setPinned(id: found.id, true)
            }
        }
        check("clipboard pins: no more than clipboardMaxPinnedImages images",
              store.pinnedCount == Config.clipboardMaxPinnedImages)
        store.add(.text("text"), source: ClipSource(name: nil, bundleID: nil))
        check("clipboard pins: text can still be pinned past the image limit",
              store.items.first { $0.content == .text("text") }.map { store.setPinned(id: $0.id, true) } == true)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
