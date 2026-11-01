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
import ImageIO

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
            // Both the displayed "1920 × 1080" and a typed "1920x1080" match.
            let searchable = "Image: \(image.dimensions) \(image.pixelWidth)x\(image.pixelHeight)"
            return searchable.localizedCaseInsensitiveContains(query)
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

    /// Sizes outside this range are refused, so pixelWidth * pixelHeight can
    /// never overflow, even for a hand-edited history file.
    static func isValidSize(width: Int, height: Int) -> Bool {
        (1...100_000).contains(width) && (1...100_000).contains(height)
    }

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
        guard Self.isValidSize(width: pixelWidth, height: pixelHeight) else {
            throw DecodingError.dataCorruptedError(forKey: .pixelWidth, in: container, debugDescription: "Bad image size")
        }
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
            let paths = try container.decode([String].self, forKey: .paths)
            // The panel shows paths[0], so never let an empty list in, even
            // from a hand-edited history file.
            guard !paths.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .paths, in: container, debugDescription: "No file paths")
            }
            self = .files(paths)
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
struct ClipSource: Sendable {
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
    let imagesDirectory: URL
    private var saveTimer: Timer?
    private var pruneTimer: Timer?

    /// Image files this process has referenced. Only these are ever deleted
    /// when unused: another running copy of the launcher (say ./Launcher and
    /// build/Launcher.app) shares the folder, and its images aren't ours.
    private var knownImageFiles = Set<String>()

    /// ~/Library/Application Support/Launcher. Also holds the lock file that
    /// keeps a second copy of the launcher from running (see LauncherApp).
    static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Launcher", isDirectory: true)
    }()

    override init() {
        let directory = Self.directory
        fileURL = directory.appendingPathComponent("clipboard-history.json")
        imagesDirectory = directory.appendingPathComponent("clipboard-images", isDirectory: true)
        super.init()

        load()
        let lostImages = dropItemsWithMissingImages()
        knownImageFiles = usedImageFiles()
        if prune() || lostImages { saveNow() }
        removeStaleImages()

        // Expire old items even when nothing new is being copied.
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(pruneTick), userInfo: nil, repeats: true)
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    /// Records a copy made at `copiedAt`. Copying something already in the
    /// history moves it up instead of adding a duplicate.
    ///
    /// Images arrive late (they're converted in the background), so an item
    /// is placed by its time rather than always at the top.
    func add(_ content: ClipContent, source: ClipSource, copiedAt: Date = Date()) {
        if case .image(let image) = content {
            // Written by ClipImageFile.save before this call. If it's gone
            // already, there's nothing to show or restore.
            guard FileManager.default.fileExists(atPath: imageURL(for: image).path) else { return }
            knownImageFiles.insert(image.fileName)
        }
        items.removeAll { $0.content == content }
        let item = ClipItem(
            id: UUID(),
            copiedAt: copiedAt,
            sourceApp: source.name,
            sourceBundleID: source.bundleID,
            content: content
        )
        let index = items.firstIndex { $0.copiedAt <= copiedAt } ?? items.count
        items.insert(item, at: index)
        UsageStats.shared.recordClipboardCopy(content, bundleID: source.bundleID)
        if items.count > Config.clipboardMaxItems {
            items.removeLast(items.count - Config.clipboardMaxItems)
        }
        didChange()
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
        if case .image(let image) = item.content {
            // Keeps removeStaleImages (in this or another running copy) off it.
            ClipImageFile.touch(imageURL(for: image))
        }
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
    /// Then deletes the image files of items this process has dropped.
    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            // Clipboard contents can be sensitive: owner-only access.
            try ClipImageFile.createPrivateDirectory(fileURL.deletingLastPathComponent())
            let data = try encoder.encode(StoredHistory(items: items))
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Launcher: could not save clipboard history: \(error)")
            return
        }
        removeUnusedImages()
    }

    /// Deletes the files of images this process knew about and no longer
    /// uses (expired, deleted, cleared, or pushed out by clipboardMaxItems).
    private func removeUnusedImages() {
        let used = usedImageFiles()
        for name in knownImageFiles.subtracting(used) {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
        knownImageFiles = used
    }

    /// Run at launch: deletes image files nobody can be using any more, left
    /// behind by a crash or by a history file that could not be read. A file
    /// still in some history is younger than the retention period, because
    /// copying an image again or picking it from the panel refreshes its date.
    private func removeStaleImages() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) else { return }
        let cutoff = Date().addingTimeInterval(-Config.clipboardRetention - 60 * 60)
        let used = usedImageFiles()
        for name in names where !used.contains(name) {
            let url = imagesDirectory.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func usedImageFiles() -> Set<String> {
        var used = Set<String>()
        for item in items {
            if case .image(let image) = item.content { used.insert(image.fileName) }
        }
        return used
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            items = try decoder.decode(StoredHistory.self, from: data).items
        } catch {
            // Set it aside rather than overwrite it with an empty history on
            // the next save, in case it can be recovered by hand.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("Launcher: unreadable clipboard history moved to \(backup.path): \(error)")
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

    /// Every image format NSImage reads, PNG and TIFF first since those
    /// need the least conversion.
    private static let imageTypes: [NSPasteboard.PasteboardType] =
        [.png, .tiff] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }

    /// Only reads the clipboard's contents when its change counter moved.
    ///
    /// One copy often carries several representations, and only one is
    /// recorded:
    /// - files, unless they are temporary copies of an image that is also on
    ///   the clipboard (chat apps do this; the temp file soon disappears);
    /// - text, unless it is only the link of an image that is also on the
    ///   clipboard (a browser's "Copy Image"). Apps like Excel or Keynote put a
    ///   picture next to real text, and the text is what you want back;
    /// - otherwise the image.
    @objc private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let types = pasteboard.types ?? []
        guard !types.contains(where: { Self.ignoredTypes.contains($0) }) else {
            UsageStats.shared.record(.clipboardSkippedMarked)
            return
        }

        let source = ClipSource.frontmost
        let copiedAt = Date()
        let imageType = pasteboard.availableType(from: Self.imageTypes)
        let filePaths = readFilePaths()
        let text = filePaths == nil ? readText() : nil

        let preferImage: Bool
        if let filePaths {
            preferImage = filePaths.allSatisfy(Self.isTemporary)
        } else if let text {
            preferImage = Self.isLink(text)
        } else {
            // Text that was refused (too large, or only whitespace) is still
            // the copy's real content: record nothing rather than the picture
            // apps like Excel put next to it.
            preferImage = !types.contains(.string)
        }

        if preferImage, let imageType {
            recordImage(type: imageType, source: source, copiedAt: copiedAt)
        } else if let filePaths {
            store.add(.files(filePaths), source: source, copiedAt: copiedAt)
        } else if let text {
            store.add(.text(text), source: source, copiedAt: copiedAt)
        } else if types.contains(.string) {
            // Text refused by readText (too large, or only whitespace).
            UsageStats.shared.record(.clipboardSkippedText)
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

    /// Reads the image's bytes here (the clipboard is read on the main
    /// thread) and checks its pixel size from the header alone. Decoding,
    /// PNG conversion, hashing and writing happen in the background, so a
    /// huge image can't freeze the panels.
    private func recordImage(type: NSPasteboard.PasteboardType, source: ClipSource, copiedAt: Date) {
        guard let data = pasteboard.data(forType: type) else { return }
        if let size = ClipImageFile.pixelSize(of: data), !ClipImageFile.isAcceptable(size) {
            UsageStats.shared.record(.clipboardSkippedImage)
            return
        }

        let store = self.store
        let directory = store.imagesDirectory
        Task.detached(priority: .userInitiated) {
            guard let image = ClipImageFile.save(data, type: type, in: directory) else {
                await MainActor.run { UsageStats.shared.record(.clipboardSkippedImage) }
                return
            }
            await store.add(.image(image), source: source, copiedAt: copiedAt)
        }
    }

    /// Temporary or cache locations, where apps put throwaway copies.
    private static func isTemporary(_ path: String) -> Bool {
        let prefixes = ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]
        return prefixes.contains { path.hasPrefix($0) } || path.contains("/Library/Caches/")
    }

    /// A single web link, such as the address a browser adds when copying an
    /// image.
    private static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let scheme = URL(string: trimmed)?.scheme?.lowercased()
        else { return false }
        return scheme == "http" || scheme == "https"
    }
}

// MARK: - Image files

/// Image conversion and file writing. Nothing here touches the main actor,
/// so ClipboardMonitor runs it in the background.
enum ClipImageFile {
    /// Pixel size from the image's header, without decoding it. nil for
    /// formats ImageIO can't read (PDF).
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    static func isAcceptable(_ size: (width: Int, height: Int)) -> Bool {
        ClipImage.isValidSize(width: size.width, height: size.height)
            && size.width * size.height <= Config.clipboardMaxImagePixels
    }

    /// Converts to PNG, checks the limits and writes `<sha256>.png` into
    /// `directory` (or refreshes the date of an identical file already there).
    static func save(_ data: Data, type: NSPasteboard.PasteboardType, in directory: URL) -> ClipImage? {
        guard let png = pngData(from: data, type: type),
              png.count <= Config.clipboardMaxImageBytes,
              let size = pixelSize(of: png),
              isAcceptable(size)
        else { return nil }

        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let image = ClipImage(hash: hash, pixelWidth: size.width, pixelHeight: size.height, byteCount: png.count)
        let url = directory.appendingPathComponent(image.fileName)
        let fileManager = FileManager.default
        do {
            try createPrivateDirectory(directory)
            if fileManager.fileExists(atPath: url.path) {
                touch(url)
            } else {
                try png.write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            NSLog("Launcher: could not save clipboard image: \(error)")
            return nil
        }
        return image
    }

    /// Marks the file as in use (see ClipboardStore.removeStaleImages).
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func pngData(from data: Data, type: NSPasteboard.PasteboardType) -> Data? {
        if type == .png { return data }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        // PDF and anything else ImageIO doesn't read, at its natural size.
        guard let tiff = NSImage(data: data)?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
