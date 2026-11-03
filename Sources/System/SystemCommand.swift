// SystemCommand.swift
//
// What an alfresco://system/... URL from workflows.json asks macOS to do:
// sleep, lock the screen, or turn the display off. None of these needs a
// permission prompt.

import AppKit

enum SystemCommand: Equatable, Sendable {
    case sleep
    case lock
    case displaySleep

    /// The host of its alfresco:// URLs.
    static let feature = "system"

    /// alfresco://system/<action>, where <action> is sleep, lock or
    /// displaysleep. nil for anything else, so the launcher can beep.
    init?(url: URL) {
        switch InternalURL.action(of: url, feature: Self.feature) {
        case "sleep": self = .sleep
        case "lock": self = .lock
        case "displaysleep": self = .displaySleep
        default: return nil
        }
    }

    /// How long sleep and display sleep wait, so the launcher has faded out
    /// and releasing Enter doesn't wake the Mac or the display right away.
    static let delay: TimeInterval = 0.5

    /// Runs the command. False (the launcher beeps) when it can't be run:
    /// the lock function is missing or fails, or pmset is missing. pmset
    /// runs after `delay`, once the launcher has closed, so a pmset that
    /// then fails to start or exits non-zero beeps by itself.
    @MainActor
    func run() -> Bool {
        switch self {
        case .sleep: return Self.pmset("sleepnow")
        case .displaySleep: return Self.pmset("displaysleepnow")
        case .lock:
            guard let lock = Self.lockScreen else { return false }
            return lock() == 0
        }
    }

    private static let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")

    /// Runs `pmset <argument>` after `delay`. pmset needs no admin rights
    /// for these two.
    @MainActor
    private static func pmset(_ argument: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: pmsetURL.path) else { return false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let process = Process()
            process.executableURL = pmsetURL
            process.arguments = [argument]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                guard process.terminationStatus != 0 else { return }
                Task { @MainActor in NSSound.beep() }
            }
            do {
                try process.run()
            } catch {
                NSSound.beep()
            }
        }
        return true
    }

    private typealias LockFunction = @convention(c) () -> Int32

    /// SACLockScreenImmediate from the private login framework: what the
    /// Apple menu's Lock Screen (⌃⌘Q) calls. It needs no Accessibility
    /// access, unlike posting ⌃⌘Q. Returns 0 on success. nil if a future
    /// macOS drops it.
    @MainActor private static let lockScreen: LockFunction? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    #if SELFTEST
    /// Whether `lock` can run on this macOS, without locking.
    @MainActor static var lockAvailableForSelfTest: Bool { lockScreen != nil }
    #endif
}
