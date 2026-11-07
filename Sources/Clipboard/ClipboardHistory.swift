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

    /// Its kind, for signpost metadata.
    var signpostKind: Signposts.Kind {
        switch self {
        case .text: return .text
        case .image: return .image
        case .files: return .files
        }
    }
}

extension ClipContent {
    /// The SF Symbol of the kind, where no picture of the clip is shown.
    var symbolName: String {
        switch self {
        case .text: return "doc.plaintext"
        case .image: return "photo"
        case .files: return "doc"
        }
    }

    /// One line describing the clip: its text on one line, "Image: 4 × 3",
    /// or the files' names. Used by the history's rows and the launcher's
    /// snippets list.
    var summary: String {
        switch self {
        case .text(let text): return Self.singleLine(text)
        case .image(let image): return "Image: \(image.dimensions)"
        case .files(let paths): return Self.fileNames(paths)
        }
    }

    /// The start of `text` with every run of whitespace (line breaks
    /// included) made one space. Only the start: copied text can be huge.
    static func singleLine(_ text: String) -> String {
        text.prefix(400)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// "invoice.pdf", or "3 files: a.pdf, b.pdf, c.pdf".
    static func fileNames(_ paths: [String]) -> String {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        return names.count == 1 ? names[0] : "\(names.count) files: \(names.joined(separator: ", "))"
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
    /// Pinned items stay at the top of the history and never expire: neither
    /// Config.clipboardRetention nor Config.clipboardMaxItems removes them,
    /// and Clear Clipboard History keeps them. Absent (false) in history
    /// written by older builds. An older build reading a newer file ignores
    /// it: a pinned item copied more than a retention period ago is deleted
    /// there, with its image file, and is gone for good (older builds don't
    /// check StoredHistory.version, so bumping it wouldn't stop them).
    var pinned = false
    /// The snippet name of a pinned item (`sig`, typed as `/snip sig` in the
    /// launcher), always SnippetName.normalize'd and unique in the history;
    /// nil for an unpinned one. Absent (nil) in history written by older
    /// builds, which drop it on their next save.
    var snippetName: String?

    private enum CodingKeys: String, CodingKey {
        case id, copiedAt, sourceApp, sourceBundleID, content, pinned, snippetName
    }
}

extension ClipItem {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        copiedAt = try container.decode(Date.self, forKey: .copiedAt)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        content = try container.decode(ClipContent.self, forKey: .content)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        // A hand-edited name that isn't a usable one is dropped, never the item.
        let name = try? container.decodeIfPresent(String.self, forKey: .snippetName)
        snippetName = pinned ? name.flatMap(SnippetName.normalize) : nil
    }
}

/// File format: { "version": 1, "items": [...] }, pinned items first, then
/// newest first.
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

/// The history, pinned items first (most recently pinned on top), then the
/// rest newest first, persisted to
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
    /// False when an unreadable history file couldn't be set aside: saving
    /// would overwrite it, so nothing is saved until the next launch.
    private var canSave = true

    /// ~/Library/Application Support/Launcher. Also holds the lock file that
    /// keeps a second copy of the launcher from running (see LauncherApp).
    static let directory: URL = {
        #if SELFTEST
        // The self-test keeps its files out of the real support folder.
        if let path = ProcessInfo.processInfo.environment["ALFRESCO_SUPPORT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Launcher", isDirectory: true)
    }()

    /// `directory` is only ever another one in the self-test.
    init(directory: URL = ClipboardStore.directory) {
        fileURL = directory.appendingPathComponent("clipboard-history.json")
        imagesDirectory = directory.appendingPathComponent("clipboard-images", isDirectory: true)
        super.init()
        ClipImageFile.makePrivate(directory)
        ClipImageFile.makePrivate(imagesDirectory)

        let launch = Signposts.signposter.beginInterval("clipboard.store.init")
        load()
        let lostImages = dropItemsWithMissingImages()
        knownImageFiles = usedImageFiles()
        // A pinned image can be far older than the retention period: a fresh
        // date keeps removeStaleImages (in this or another copy) off its file.
        for item in items where item.pinned {
            if case .image(let image) = item.content { ClipImageFile.touch(imageURL(for: image)) }
        }
        if prune() || lostImages { saveNow() }
        removeStaleImages()
        removeStaleSetAsideFiles()
        Signposts.signposter.endInterval("clipboard.store.init", launch, "items=\(self.items.count, privacy: .public)")

        // Expire old items even when nothing new is being copied.
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(pruneTick), userInfo: nil, repeats: true)
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    /// The number of pinned items, which come first in `items`.
    var pinnedCount: Int {
        items.prefix(while: \.pinned).count
    }

    /// Records a copy made at `copiedAt`. Copying something already in the
    /// history moves it up instead of adding a duplicate; copying a pinned
    /// item's content again leaves the pinned item where it is.
    ///
    /// Images arrive late (they're converted in the background), so an item
    /// is placed by its time rather than always at the top of the unpinned
    /// ones.
    func add(_ content: ClipContent, source: ClipSource, copiedAt: Date = Date()) {
        if case .image(let image) = content {
            // Written by ClipImageFile.save before this call. If it's gone
            // already, there's nothing to show or restore.
            guard FileManager.default.fileExists(atPath: imageURL(for: image).path) else { return }
            knownImageFiles.insert(image.fileName)
        }
        if let index = items.firstIndex(where: { $0.pinned && $0.content == content }) {
            items[index].copiedAt = max(items[index].copiedAt, copiedAt)
            UsageStats.shared.recordClipboardCopy(content, bundleID: source.bundleID)
            didChange()
            return
        }
        items.removeAll { $0.content == content }
        let item = ClipItem(
            id: UUID(),
            copiedAt: copiedAt,
            sourceApp: source.name,
            sourceBundleID: source.bundleID,
            content: content
        )
        let index = items.firstIndex { !$0.pinned && $0.copiedAt <= copiedAt } ?? items.count
        items.insert(item, at: index)
        UsageStats.shared.recordClipboardCopy(content, bundleID: source.bundleID)
        // Only unpinned items count, and they are the last ones.
        let unpinned = items.count - pinnedCount
        if unpinned > Config.clipboardMaxItems {
            items.removeLast(unpinned - Config.clipboardMaxItems)
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
    /// picked from the history panel), restarting its retention period. A
    /// pinned item keeps its place among the pinned ones, so they stay in
    /// the order they were pinned.
    func promote(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.copiedAt = Date()
        items.insert(item, at: item.pinned ? index : pinnedCount)
        touchImage(of: item)
        didChange()
    }

    /// Pins an item (it goes to the top) or unpins it (it goes to the top of
    /// the unpinned items with a fresh timestamp, so it gets a full retention
    /// period rather than expiring at once). Returns false, changing nothing,
    /// when the item is gone, Config.clipboardMaxPinnedItems are pinned, or
    /// it is an image and Config.clipboardMaxPinnedImages images are.
    @discardableResult
    func setPinned(id: UUID, _ pinned: Bool) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].pinned != pinned else { return true }
        if pinned {
            if pinnedCount >= Config.clipboardMaxPinnedItems { return false }
            if case .image = items[index].content {
                let pinnedImages = items.prefix(pinnedCount).filter { item in
                    if case .image = item.content { return true }
                    return false
                }.count
                if pinnedImages >= Config.clipboardMaxPinnedImages { return false }
            }
        }
        var item = items.remove(at: index)
        item.pinned = pinned
        // Only pinned items are snippets: an unpinned one would expire.
        if !pinned { item.snippetName = nil }
        if pinned {
            items.insert(item, at: 0)
        } else {
            item.copiedAt = Date()
            items.insert(item, at: pinnedCount)
        }
        touchImage(of: item)
        didChange()
        return true
    }

    /// Names an item as a snippet (`sig`, typed as `/snip sig` in the
    /// launcher), pinning it first if it isn't, or removes its name with nil
    /// or a blank `name`. Another item holding the name loses it. Returns
    /// false, changing nothing, when the item is gone, the name isn't a
    /// usable one (SnippetName.normalize), or it can't be pinned (setPinned).
    @discardableResult
    func setSnippetName(id: UUID, _ name: String?) -> Bool {
        guard items.contains(where: { $0.id == id }) else { return false }
        let removing = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let normalized = removing ? nil : name.flatMap(SnippetName.normalize)
        guard removing || (normalized != nil && setPinned(id: id, true)) else { return false }
        // setPinned may have moved it.
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].snippetName != normalized else { return true }
        if let normalized {
            for other in items.indices where items[other].snippetName == normalized {
                items[other].snippetName = nil
            }
        }
        items[index].snippetName = normalized
        didChange()
        return true
    }

    /// Keeps removeStaleImages (in this or another running copy) off an
    /// image item's file.
    private func touchImage(of item: ClipItem) {
        if case .image(let image) = item.content {
            ClipImageFile.touch(imageURL(for: image))
        }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        didChange()
    }

    /// Deletes every item except the pinned ones.
    func clear() {
        items.removeAll { !$0.pinned }
        didChange()
    }

    #if SELFTEST
    /// Puts back a list read from `items` earlier, without saving: the perf
    /// suite keeps its seeded history whole between runs.
    func replaceItemsForSelfTest(_ items: [ClipItem]) { self.items = items }

    /// Stops the timers, which hold on to the store, so one made only to be
    /// measured is freed.
    func stopTimersForSelfTest() {
        pruneTimer?.invalidate()
        pruneTimer = nil
        saveTimer?.invalidate()
        saveTimer = nil
    }
    #endif

    /// Deletes unpinned items past their retention period, from memory and
    /// disk.
    func expireOldItems() {
        if prune() { didChange() }
    }

    /// Returns whether any items were removed.
    private func prune() -> Bool {
        let cutoff = Date().addingTimeInterval(-Config.clipboardRetention)
        let before = items.count
        items.removeAll { !$0.pinned && $0.copiedAt < cutoff }
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
        removeStaleSetAsideFiles()
    }

    private func didChange() {
        scheduleSave()
        onChange?()
    }

    // MARK: Persistence

    /// Coalesces bursts of changes into one write.
    private func scheduleSave() {
        guard canSave else { return }
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
        guard canSave else { return }

        let signposter = Signposts.signposter
        let save = signposter.beginInterval("clipboard.save", "items=\(self.items.count, privacy: .public)")
        defer { signposter.endInterval("clipboard.save", save) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            // Clipboard contents can be sensitive: owner-only access.
            try ClipImageFile.createPrivateDirectory(fileURL.deletingLastPathComponent())
            let data = try signposter.withIntervalSignpost(
                "clipboard.save.encode", "items=\(self.items.count, privacy: .public)"
            ) {
                try encoder.encode(StoredHistory(items: items))
            }
            try signposter.withIntervalSignpost("clipboard.save.write", "bytes=\(data.count, privacy: .public)") {
                try data.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                // The atomic write replaced the file, and with it the flag.
                excludeFromBackup(fileURL)
            }
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
    /// copying an image again, picking or pinning it, and (for a pinned one)
    /// each launch refresh its date.
    private func removeStaleImages() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) else { return }
        let used = usedImageFiles()
        for name in names where !used.contains(name) {
            let url = imagesDirectory.appendingPathComponent(name)
            // An hour of slack for a file another copy is about to touch.
            if Self.isPastRetention(url, margin: 60 * 60) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Run at launch and on each prune: deletes the history files set aside
    /// by load (clipboard-history.unreadable*.json) once a retention period
    /// has passed since they were set aside, so they don't keep old clips
    /// forever.
    private func removeStaleSetAsideFiles() {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let prefix = fileURL.deletingPathExtension().lastPathComponent + ".unreadable"
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            if Self.isPastRetention(url) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Whether the file was last modified more than the retention period
    /// (plus `margin`) ago.
    private static func isPastRetention(_ url: URL, margin: TimeInterval = 0) -> Bool {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified else { return false }
        return modified < Date().addingTimeInterval(-Config.clipboardRetention - margin)
    }

    private func usedImageFiles() -> Set<String> {
        var used = Set<String>()
        for item in items {
            if case .image(let image) = item.content { used.insert(image.fileName) }
        }
        return used
    }

    private func load() {
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval("clipboard.load")
        var bytes = 0
        defer {
            signposter.endInterval(
                "clipboard.load", signpost, "bytes=\(bytes, privacy: .public) items=\(self.items.count, privacy: .public)"
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return  // First launch: no history yet.
        } catch {
            setAside(error)
            return
        }
        bytes = data.count
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let loaded = try signposter.withIntervalSignpost("clipboard.load.decode", "bytes=\(data.count, privacy: .public)") {
                try decoder.decode(StoredHistory.self, from: data).items
            }
            // Pinned first, whatever the file says, so pinnedCount holds.
            var pinned = loaded.filter(\.pinned)
            // A hand-edited file could give two items one name: the first keeps it.
            var names = Set<String>()
            for index in pinned.indices {
                guard let name = pinned[index].snippetName else { continue }
                if !names.insert(name).inserted { pinned[index].snippetName = nil }
            }
            items = pinned + loaded.filter { !$0.pinned }
        } catch {
            setAside(error)
        }
    }

    /// Moves an unreadable history file out of the way rather than overwrite
    /// it with an empty history on the next save, in case it can be recovered
    /// by hand. If it can't be moved, nothing is saved this run.
    private func setAside(_ error: Error) {
        if let backup = SetAsideFile.move(fileURL) {
            // It keeps the date of its last save, which could be past the
            // retention period already: give it a full period to be recovered.
            ClipImageFile.touch(backup)
            excludeFromBackup(backup)
            NSLog("Launcher: unreadable clipboard history moved to \(backup.path): \(error)")
        } else {
            canSave = false
            NSLog("Launcher: could not set aside unreadable clipboard history, so it won't be saved this run: \(error)")
        }
    }
}

/// Keeps clipboard contents (which can hold copied passwords and tokens) out
/// of new Time Machine backups, so they don't outlive the retention period
/// there. Earlier backups are not changed. Set on the history file after each
/// save (an atomic write replaces it, and the flag with it) and on the images
/// folder; the rest of the support folder is still backed up.
func excludeFromBackup(_ url: URL) {
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
}

// MARK: - Monitor

/// Watches the system clipboard and records new copies in the store.
@MainActor
final class ClipboardMonitor: NSObject {
    /// Markers apps put on the clipboard to ask clipboard managers not to
    /// record an item: passwords (1Password, Bitwarden, Keychain Access, ...),
    /// one-off transient data, and auto-generated content.
    /// See http://nspasteboard.org. The last ones are the older, app-specific
    /// markers that came before it and that some apps still use.
    private static let ignoredTypes: Set<NSPasteboard.PasteboardType> = Set([
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type",
        "com.typeit4me.clipping",
        "net.antelle.keeweb",
    ].map { NSPasteboard.PasteboardType($0) })

    private let store: ClipboardStore
    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var timer: Timer?

    /// `pasteboard` is only ever another one in the self-test.
    init(store: ClipboardStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
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

    /// The image formats ClipImageFile.save can turn into a PNG: what ImageIO
    /// reads, and PDF (pdfPNGData). PNG and TIFF first since those need the
    /// least conversion. Other formats NSImage lists (EPS, say) are left out,
    /// so such a copy records its text or files instead of an image that
    /// could not be saved.
    private static let imageTypes: [NSPasteboard.PasteboardType] = {
        let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []).union(["com.adobe.pdf"])
        let others = NSImage.imageTypes.filter { readable.contains($0) }
        return [.png, .tiff] + others.map { NSPasteboard.PasteboardType($0) }
    }()

    #if SELFTEST
    static var imageTypesForSelfTest: [NSPasteboard.PasteboardType] { imageTypes }
    #endif

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

        // Only polls that read the clipboard; an image's conversion is
        // ClipImageFile.save's own interval.
        let signpost = Signposts.signposter.beginInterval("clipboard.poll")
        var recorded = Signposts.Kind.none
        defer { Signposts.end("clipboard.poll", signpost, recorded) }

        let types = pasteboard.types ?? []
        guard !types.contains(where: { Self.ignoredTypes.contains($0) }) else {
            recorded = .marked
            UsageStats.shared.record(.clipboardSkippedMarked)
            return
        }
        let source = ClipSource.frontmost
        guard !Self.isIgnored(source) else {
            recorded = .ignored
            UsageStats.shared.record(.clipboardSkippedApp)
            return
        }

        let copiedAt = Date()
        let imageType = pasteboard.availableType(from: Self.imageTypes)
        let filePaths = readFilePaths()
        let text = filePaths == nil ? readText() : nil
        // Another copy since the markers were checked: what was just read
        // may be that one, unchecked. The next poll looks at it properly.
        guard pasteboard.changeCount == changeCount else { return }

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
            recorded = recordImage(type: imageType, changeCount: changeCount, source: source, copiedAt: copiedAt)
        } else if let filePaths {
            recorded = .files
            store.add(.files(filePaths), source: source, copiedAt: copiedAt)
        } else if let text {
            recorded = .text
            store.add(.text(text), source: source, copiedAt: copiedAt)
        } else if types.contains(.string) {
            // Text refused by readText (too large, or only whitespace).
            recorded = .skipped
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
        guard let text = pasteboard.string(forType: .string), Self.isRecordable(text) else { return nil }
        return text
    }

    /// Not too large, and not only whitespace. The size comes first, and the
    /// whitespace check stops at the first visible scalar, so no trimmed copy
    /// of the text is ever made (a huge copy used to be duplicated just to be
    /// turned down). Scalars, not Characters: a space carrying a combining
    /// mark is one Character that Character.isWhitespace calls blank, but
    /// trimming whitespace leaves the mark, so it counts as text, as before.
    private static func isRecordable(_ text: String) -> Bool {
        text.utf8.count <= Config.clipboardMaxTextBytes
            && text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    #if SELFTEST
    static func isRecordableForSelfTest(_ text: String) -> Bool { isRecordable(text) }
    #endif

    /// Reads the image's bytes here (the clipboard is read on the main
    /// thread) and checks its pixel size from the header alone. Decoding,
    /// PNG conversion, hashing and writing happen in the background, so a
    /// huge image can't freeze the panels. Returns `.image` once the save is
    /// started (it can still fail: see the clipboard.image.save interval).
    private func recordImage(
        type: NSPasteboard.PasteboardType, changeCount: Int, source: ClipSource, copiedAt: Date
    ) -> Signposts.Kind {
        guard let data = pasteboard.data(forType: type) else {
            UsageStats.shared.record(.clipboardSkippedImage)
            return .skipped
        }
        // As in poll: a newer copy's image, read before its markers were checked.
        guard pasteboard.changeCount == changeCount else { return .none }
        if let size = ClipImageFile.pixelSize(of: data), !ClipImageFile.isAcceptable(size) {
            UsageStats.shared.record(.clipboardSkippedImage)
            return .skipped
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
        return .image
    }

    /// Copies made in an app of Config.clipboardIgnoredApps.
    private static func isIgnored(_ source: ClipSource) -> Bool {
        source.bundleID.map { Config.clipboardIgnoredApps.contains($0) } ?? false
    }

    #if SELFTEST
    func pollForSelfTest() { poll() }
    static func isIgnoredForSelfTest(_ source: ClipSource) -> Bool { isIgnored(source) }
    #endif

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
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval(
            "clipboard.image.save", id: signposter.makeSignpostID(), "bytes=\(data.count, privacy: .public)"
        )
        let image = convertAndWrite(data, type: type, in: directory)
        if let image {
            signposter.endInterval(
                "clipboard.image.save", signpost,
                "png=\(image.byteCount, privacy: .public) pixels=\(image.pixelWidth, privacy: .public)x\(image.pixelHeight, privacy: .public)"
            )
        } else {
            Signposts.end("clipboard.image.save", signpost, .failed)
        }
        return image
    }

    private static func convertAndWrite(_ data: Data, type: NSPasteboard.PasteboardType, in directory: URL) -> ClipImage? {
        // recordImage checked this already; repeated so no caller can have a
        // huge image decoded. A PNG is kept as is and checked just below.
        if type != .png, let size = pixelSize(of: data), !isAcceptable(size) { return nil }
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
            excludeFromBackup(directory)
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

    /// Makes an existing folder owner-only: createPrivateDirectory's
    /// attributes only apply to a folder it creates, and earlier builds made
    /// these without them. Run once at launch; a folder that can't be changed
    /// is left as it is (saving still works, as before).
    static func makePrivate(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            NSLog("Launcher: could not make %@ owner-only: %@", url.path, error.localizedDescription)
        }
    }

    private static func pngData(from data: Data, type: NSPasteboard.PasteboardType) -> Data? {
        if type == .png { return data }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        // ImageIO can't read it: a PDF (the only other type the monitor
        // reads, see ClipboardMonitor.imageTypes).
        return pdfPNGData(from: data)
    }

    /// The first page of a PDF, drawn at one pixel per point into a bitmap
    /// of exactly that size. Its header gave no pixel size (see recordImage),
    /// so the size is checked here, before anything is drawn: the bitmap's
    /// size is set here, not by the screen's scale, so a huge page is turned
    /// down instead of taking gigabytes.
    private static func pdfPNGData(from data: Data) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1)
        else { return nil }
        var box = page.getBoxRect(.cropBox).size
        if page.rotationAngle % 180 != 0 { box = CGSize(width: box.height, height: box.width) }
        let width = box.width.rounded(.up)
        let height = box.height.rounded(.up)
        guard width >= 1, height >= 1, width <= 100_000, height <= 100_000 else { return nil }
        let size = (width: Int(width), height: Int(height))
        guard isAcceptable(size),
              let context = CGContext(
                  data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
