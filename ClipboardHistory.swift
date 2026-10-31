// ClipboardHistory.swift
//
// Records what you copy (⌘C keeps working exactly as before; this only
// watches the clipboard) and keeps it on disk for Config.clipboardRetention.
//
// Three kinds are recorded: text, images and file references (what Finder
// puts on the clipboard when you copy files). To add another, add a
// ClipContent case, teach ClipboardMonitor to read it and ClipboardController
// to show and restore it. The on-disk format tags every item with a "kind",
// so older builds skip kinds they don't know.

import Cocoa
import CryptoKit

// MARK: - Model

enum ClipContent: Equatable, Sendable {
    case text(String)
    /// The image data lives in the store's images folder, not in the JSON.
    case image(ClipImage)
    /// Absolute paths of copied files and folders. Only the references are
    /// kept: the files themselves are not copied, so a moved or deleted file
    /// can no longer be restored.
    case files([String])

    /// Case-insensitive search used by the history panel's filter field.
    func matches(_ query: String) -> Bool {
        switch self {
        case .text(let text):
            return text.localizedCaseInsensitiveContains(query)
        case .image(let image):
            return "Image \(image.dimensions)".localizedCaseInsensitiveContains(query)
        case .files(let paths):
            return paths.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// An image clip. Its PNG data is stored as `<sha256>.png` in the store's
/// images folder; identical images share one file and count as one clip.
struct ClipImage: Codable, Equatable, Sendable {
    /// Lowercase hex SHA-256 of the PNG data.
    let hash: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// Size of the stored PNG.
    let byteCount: Int

    var fileName: String { "\(hash).png" }
    var dimensions: String { "\(pixelWidth) × \(pixelHeight)" }

    init(hash: String, pixelWidth: Int, pixelHeight: Int, byteCount: Int) {
        self.hash = hash
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case hash, pixelWidth, pixelHeight, byteCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        // The hash becomes a file name: never trust it to be a safe one.
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw DecodingError.dataCorruptedError(forKey: .hash, in: container, debugDescription: "Not a SHA-256 hash")
        }
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
    }

    static func == (lhs: ClipImage, rhs: ClipImage) -> Bool {
        lhs.hash == rhs.hash
    }
}

extension ClipContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, image, paths
    }

    private enum Kind: String, Codable {
        case text, image, files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .image:
            self = .image(try container.decode(ClipImage.self, forKey: .image))
        case .files:
            self = .files(try container.decode([String].self, forKey: .paths))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .image(let image):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(image, forKey: .image)
        case .files(let paths):
            try container.encode(Kind.files, forKey: .kind)
            try container.encode(paths, forKey: .paths)
        }
    }
}

struct ClipItem: Codable, Identifiable, Sendable {
    let id: UUID
    var copiedAt: Date
    /// Name of the app that was frontmost when the item was copied.
    let sourceApp: String?
    /// Bundle identifier of that app, used to show its icon. Absent in
    /// history written by older builds.
    let sourceBundleID: String?
    let content: ClipContent
}

/// File format: { "version": 1, "items": [...] }, newest item first.
private struct StoredHistory: Codable {
    static let currentVersion = 1

    var version: Int
    var items: [ClipItem]

    init(items: [ClipItem]) {
        version = Self.currentVersion
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        // One unreadable item (say, a kind written by a newer build) should
        // not cost the whole history.
        items = try container.decode([Lossy<ClipItem>].self, forKey: .items).compactMap(\.value)
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// The app an item was copied from.
struct ClipSource {
    let name: String?
    let bundleID: String?

    static var frontmost: ClipSource {
        let app = NSWorkspace.shared.frontmostApplication
        return ClipSource(name: app?.localizedName, bundleID: app?.bundleIdentifier)
    }
}

// MARK: - Store

/// The history, newest first, persisted to
/// ~/Library/Application Support/Launcher/clipboard-history.json, with image
/// data in the clipboard-images folder next to it.
@MainActor
final class ClipboardStore: NSObject {
    private(set) var items: [ClipItem] = []

    /// Called after every change, so an open history panel can refresh.
    var onChange: (() -> Void)?

    private let fileURL: URL
    private let imagesDirectory: URL
    private var saveTimer: Timer?
    private var pruneTimer: Timer?

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = support.appendingPathComponent("Launcher", isDirectory: true)
        fileURL = directory.appendingPathComponent("clipboard-history.json")
        imagesDirectory = directory.appendingPathComponent("clipboard-images", isDirectory: true)
        super.init()

        load()
        let lostImages = dropItemsWithMissingImages()
        if prune() || lostImages { saveNow() }

        // Expire old items even when nothing new is being copied.
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(pruneTick), userInfo: nil, repeats: true)
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    /// Records a new copy. Copying something already in the history moves it
    /// to the top instead of adding a duplicate.
    func add(_ content: ClipContent, source: ClipSource) {
        items.removeAll { $0.content == content }
        let item = ClipItem(
            id: UUID(),
            copiedAt: Date(),
            sourceApp: source.name,
            sourceBundleID: source.bundleID,
            content: content
        )
        items.insert(item, at: 0)
        if items.count > Config.clipboardMaxItems {
            items.removeLast(items.count - Config.clipboardMaxItems)
        }
        didChange()
    }

    /// Stores the PNG in the images folder and records it. Unused image files
    /// are deleted when the history is saved.
    func addImage(png: Data, pixelWidth: Int, pixelHeight: Int, source: ClipSource) {
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let image = ClipImage(hash: hash, pixelWidth: pixelWidth, pixelHeight: pixelHeight, byteCount: png.count)
        let url = imageURL(for: image)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try Self.createPrivateDirectory(imagesDirectory)
                try png.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                NSLog("Launcher: could not save clipboard image: \(error)")
                return
            }
        }
        add(.image(image), source: source)
    }

    func imageURL(for image: ClipImage) -> URL {
        imagesDirectory.appendingPathComponent(image.fileName)
    }

    func imageData(for image: ClipImage) -> Data? {
        try? Data(contentsOf: imageURL(for: image))
    }

    /// Moves an item back to the top with a fresh timestamp (used when it is
    /// picked from the history panel), restarting its retention period.
    func promote(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.copiedAt = Date()
        items.insert(item, at: 0)
        didChange()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        didChange()
    }

    func clear() {
        items.removeAll()
        didChange()
    }

    /// Deletes items past their retention period, from memory and disk.
    func expireOldItems() {
        if prune() { didChange() }
    }

    /// Returns whether any items were removed.
    private func prune() -> Bool {
        let cutoff = Date().addingTimeInterval(-Config.clipboardRetention)
        let before = items.count
        items.removeAll { $0.copiedAt < cutoff }
        return items.count != before
    }

    /// Image items whose file is gone (deleted by hand, or by an older build
    /// that didn't know the kind) can't be shown or restored. Returns whether
    /// any were removed.
    private func dropItemsWithMissingImages() -> Bool {
        let before = items.count
        items.removeAll { item in
            guard case .image(let image) = item.content else { return false }
            return !FileManager.default.fileExists(atPath: imageURL(for: image).path)
        }
        return items.count != before
    }

    @objc private func pruneTick() {
        expireOldItems()
    }

    private func didChange() {
        scheduleSave()
        onChange?()
    }

    // MARK: Persistence

    /// Coalesces bursts of changes into one write.
    private func scheduleSave() {
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(saveTimerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    @objc private func saveTimerFired() {
        saveNow()
    }

    /// Writes immediately; called on quit so a pending save is not lost.
    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            // Clipboard contents can be sensitive: owner-only access.
            try Self.createPrivateDirectory(fileURL.deletingLastPathComponent())
            let data = try encoder.encode(StoredHistory(items: items))
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Launcher: could not save clipboard history: \(error)")
            return
        }
        removeUnusedImages()
    }

    /// Deletes image files no item refers to any more (expired, deleted,
    /// cleared, or pushed out by clipboardMaxItems).
    private func removeUnusedImages() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) else { return }
        var used = Set<String>()
        for item in items {
            if case .image(let image) = item.content { used.insert(image.fileName) }
        }
        for name in names where !used.contains(name) {
            try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            items = try decoder.decode(StoredHistory.self, from: data).items
        } catch {
            NSLog("Launcher: ignoring unreadable clipboard history: \(error)")
        }
    }
}

// MARK: - Monitor

/// Watches the system clipboard and records new copies in the store.
@MainActor
final class ClipboardMonitor: NSObject {
    /// Markers apps put on the clipboard to ask clipboard managers not to
    /// record an item: passwords (1Password, Bitwarden, Keychain Access, ...),
    /// one-off transient data, and auto-generated content.
    /// See http://nspasteboard.org.
    private static let ignoredTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    private let store: ClipboardStore
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    init(store: ClipboardStore) {
        self.store = store
        // Whatever was on the clipboard before launch is not recorded.
        lastChangeCount = pasteboard.changeCount
        super.init()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(
            timeInterval: Config.clipboardPollInterval,
            target: self,
            selector: #selector(poll),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = Config.clipboardPollInterval / 2
        // .common keeps polling while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Call right after the launcher itself writes to the clipboard, so that
    /// write isn't recorded as a new copy.
    func ignoreCurrentContents() {
        lastChangeCount = pasteboard.changeCount
    }

    /// Only reads the clipboard's contents when its change counter moved.
    ///
    /// One copy often carries several representations, so the first match
    /// wins: files (Finder also puts their names and icons on the clipboard),
    /// then text (apps like Excel or Keynote add a picture of the selection),
    /// then an image.
    @objc private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let types = pasteboard.types ?? []
        guard !types.contains(where: { Self.ignoredTypes.contains($0) }) else { return }

        if let paths = readFilePaths() {
            store.add(.files(paths), source: .frontmost)
        } else if let text = readText() {
            store.add(.text(text), source: .frontmost)
        } else if let image = readImage() {
            store.addImage(png: image.png, pixelWidth: image.width, pixelHeight: image.height, source: .frontmost)
        }
    }

    private func readFilePaths() -> [String]? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls, !urls.isEmpty else { return nil }
        return urls.map { $0.standardizedFileURL.path }
    }

    private func readText() -> String? {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Config.clipboardMaxTextBytes
        else { return nil }
        return text
    }

    /// Any image macOS can read off the clipboard (PNG, TIFF, PDF, ...),
    /// as PNG.
    private func readImage() -> (png: Data, width: Int, height: Int)? {
        let png: Data
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if NSImage.canInit(with: pasteboard),
                  let tiff = NSImage(pasteboard: pasteboard)?.tiffRepresentation,
                  let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            png = data
        } else {
            return nil
        }

        guard png.count <= Config.clipboardMaxImageBytes,
              let rep = NSBitmapImageRep(data: png),
              rep.pixelsWide > 0, rep.pixelsHigh > 0
        else { return nil }
        return (png, rep.pixelsWide, rep.pixelsHigh)
    }
}
