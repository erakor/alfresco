// StoreFile.swift
//
// A versioned JSON data file in the support folder, shared by the usage
// stats and the learned app picks: reading it (a newer build's file is left
// alone, a damaged one set aside), saving it 5 s after a change and on quit,
// owner-only. The owner keeps the contents and hands them in with each
// scheduleSave.

import Foundation
import os

/// Just the version, read first: it tells a newer build's file from a
/// damaged one.
private struct StoreFileVersion: Decodable {
    var version: Int
}

/// A file of an older version, which this build doesn't read.
private struct UnsupportedStoreFileVersion: Error {
    let version: Int
}

@MainActor
final class StoreFile {
    let url: URL
    /// What the file holds, for log messages ("usage stats").
    private let name: String
    /// Names the file in its signposts.
    private let kind: Signposts.Kind
    /// False when the file is from a newer build, or is unreadable and
    /// couldn't be set aside: saving would overwrite it, so nothing is saved
    /// until the next launch.
    private(set) var canSave = true
    private var saveTimer: Timer?
    /// What the pending save writes, from the latest scheduleSave. Held
    /// (with its owner) only until that save, like a timer's target.
    private var pending: (@MainActor () -> any Encodable)?

    init(url: URL, name: String, kind: Signposts.Kind) {
        self.url = url
        self.name = name
        self.kind = kind
    }

    /// The file's contents, or nil when there is none yet, or it is from a
    /// newer build (left where it is, with saving off for this run), or it
    /// can't be read (moved aside with SetAsideFile, so the next save
    /// doesn't overwrite it, or saving off if it can't be moved). Each
    /// stored type has a `version` field, `currentVersion` being the one
    /// this build reads and writes.
    func load<Stored: Decodable>(_ type: Stored.Type, currentVersion: Int) -> Stored? {
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval("store.load")
        var bytes = 0
        defer { Signposts.end("store.load", signpost, kind, bytes: bytes) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil  // Nothing saved yet.
        } catch {
            setAside(error)
            return nil
        }
        bytes = data.count
        do {
            let version = try JSONDecoder().decode(StoreFileVersion.self, from: data).version
            if version > currentVersion {
                // A newer build's file: left where it is, so that build keeps
                // what it saved when it runs again. This run saves nothing.
                canSave = false
                NSLog("Launcher: \(url.lastPathComponent) is version \(version), from a newer build; \(name) won't be saved this run")
                return nil
            }
            guard version == currentVersion else { throw UnsupportedStoreFileVersion(version: version) }
            return try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            setAside(error)
            return nil
        }
    }

    /// Saves what `contents` returns then in 5 s (or at the save already
    /// due).
    func scheduleSave(_ contents: @escaping @MainActor () -> any Encodable) {
        guard canSave else { return }
        pending = contents
        guard saveTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated { self.saveNow() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    /// Writes a pending change now (on quit, or when it can't wait).
    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let contents = pending else { return }
        pending = nil

        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval("store.save")
        var bytes = 0
        defer { Signposts.end("store.save", signpost, kind, bytes: bytes) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(contents())
            bytes = data.count
            // Usage words and typed app names: owner-only access.
            try ClipImageFile.createPrivateDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Launcher: could not save \(name): \(error)")
        }
    }

    /// Moves an unreadable file out of the way rather than overwrite it on
    /// the next save, in case it can be recovered by hand. If it can't be
    /// moved, nothing is saved this run.
    private func setAside(_ error: Error) {
        if let backup = SetAsideFile.move(url) {
            NSLog("Launcher: unreadable \(name) moved to \(backup.path): \(error)")
        } else {
            canSave = false
            NSLog("Launcher: could not set aside unreadable \(name), so they won't be saved this run: \(error)")
        }
    }
}

/// Local calendar days as "yyyy-MM-dd" keys, which sort like the dates.
enum DayKey {
    static func of(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The oldest day of the last `days` calendar days up to `now`, today
    /// included. Counted in calendar days, not 24 h steps, so a daylight
    /// saving change (a 23 or 25 hour day) doesn't move it by a day.
    static func first(keeping days: Int, upTo now: Date, in calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        return of(first, in: calendar)
    }
}
