// SetAsideFile.swift
//
// Moving a data file that can't be read out of the way, so the next save
// doesn't overwrite it and it can be recovered by hand. Used by the clipboard
// history and the usage stats.

import Foundation

enum SetAsideFile {
    /// Set-aside files kept per data file at most.
    static let maxFiles = 100

    /// Moves `url` (say history.json) to history.unreadable.json, or
    /// history.unreadable-2.json and so on when that exists: an earlier one is
    /// never replaced. nil when all `maxFiles` names are taken or the move
    /// fails; the caller must then not save over `url` (see `canSave` in
    /// ClipboardStore and UsageStats).
    static func move(_ url: URL) -> URL? {
        let base = url.deletingPathExtension()
        for number in 1...maxFiles {
            let suffix = number == 1 ? "unreadable" : "unreadable-\(number)"
            let backup = base.appendingPathExtension(suffix).appendingPathExtension("json")
            do {
                try FileManager.default.moveItem(at: url, to: backup)
                return backup
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }
}
