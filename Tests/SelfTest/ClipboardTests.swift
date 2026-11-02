// ClipboardTests.swift
//
// The clipboard history file: a damaged one is set aside, never over an
// earlier set-aside file, and never overwritten when it can't be moved.
// Set-aside files are deleted once past the retention period (counted from
// when they were set aside), and the history is excluded from backups.

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
    }
}
