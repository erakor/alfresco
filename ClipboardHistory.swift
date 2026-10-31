// ClipboardHistory.swift
//
// Records what you copy (⌘C keeps working exactly as before; this only
// watches the clipboard) and keeps it on disk for Config.clipboardRetention.
//
// Only text is recorded for now. ClipContent is the extension point for
// images and files: add a case, teach ClipboardMonitor to read it and
// ClipboardController to show and restore it. The on-disk format tags every
// item with a "kind", so older builds skip kinds they don't know.

import Cocoa

// MARK: - Model

enum ClipContent: Equatable, Sendable {
    case text(String)

    /// Case-insensitive search used by the history panel's filter field.
    func matches(_ query: String) -> Bool {
        switch self {
        case .text(let text):
            return text.localizedCaseInsensitiveContains(query)
        }
    }
}

extension ClipContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, text
    }

    private enum Kind: String, Codable {
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        }
    }
}

struct ClipItem: Codable, Identifiable, Sendable {
    let id: UUID
    var copiedAt: Date
    /// Name of the app that was frontmost when the item was copied.
    let sourceApp: String?
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

// MARK: - Store

/// The history, newest first, persisted to
/// ~/Library/Application Support/Launcher/clipboard-history.json.
@MainActor
final class ClipboardStore: NSObject {
    private(set) var items: [ClipItem] = []

    /// Called after every change, so an open history panel can refresh.
    var onChange: (() -> Void)?

    private let fileURL: URL
    private var saveTimer: Timer?
    private var pruneTimer: Timer?

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        fileURL = support
            .appendingPathComponent("Launcher", isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
        super.init()

        load()
        if prune() { saveNow() }

        // Expire old items even when nothing new is being copied.
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(pruneTick), userInfo: nil, repeats: true)
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    /// Records a new copy. Copying something already in the history moves it
    /// to the top instead of adding a duplicate.
    func add(_ content: ClipContent, sourceApp: String?) {
        items.removeAll { $0.content == content }
        items.insert(ClipItem(id: UUID(), copiedAt: Date(), sourceApp: sourceApp, content: content), at: 0)
        if items.count > Config.clipboardMaxItems {
            items.removeLast(items.count - Config.clipboardMaxItems)
        }
        didChange()
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
            let directory = fileURL.deletingLastPathComponent()
            // Clipboard contents can be sensitive: owner-only access.
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try encoder.encode(StoredHistory(items: items))
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Launcher: could not save clipboard history: \(error)")
        }
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

/// Watches the system clipboard and records new text copies in the store.
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
    @objc private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let types = pasteboard.types ?? []
        guard !types.contains(where: { Self.ignoredTypes.contains($0) }) else { return }

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Config.clipboardMaxTextBytes
        else { return }

        store.add(.text(text), sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName)
    }
}
