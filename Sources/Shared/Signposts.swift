// Signposts.swift
//
// Performance intervals for Instruments (os_signpost) and
// `log stream --signpost`; see "Measuring performance" in the root README.
// They cost next to nothing while nobody records them.
//
// Metadata is counts, sizes and kinds only: never text, queries, paths, URLs
// or bundle IDs of copied items. Numbers are interpolated with
// `privacy: .public`; the only public strings are the names of `Kind`'s
// cases, written in `end(_:_:_:)` below.
// An OSLogMessage must be written at the call that logs it, so a message
// with numbers calls `Signposts.signposter` directly.

import Foundation
import os

enum Signposts {
    static let signposter = OSSignposter(subsystem: subsystem, category: "performance")

    /// The bundle ID. The plain binary has none: it logs as the app would,
    /// except the self-test build, so `Tests/signposts.sh
    /// local.launcher.selftest` shows the self-test's intervals in both forms.
    private static var subsystem: String {
        #if SELFTEST
        return Bundle.main.bundleIdentifier ?? "local.launcher.selftest"
        #else
        return Bundle.main.bundleIdentifier ?? "local.launcher"
        #endif
    }

    /// What an interval ended with. Its name is logged as public text: these
    /// are a fixed list, never anything typed or copied.
    enum Kind: String {
        case text, image, files
        /// A copy carrying a "don't record me" marker.
        case marked
        /// A copy refused (too large, only whitespace, unreadable image).
        case skipped
        /// Nothing to record or show.
        case none
        case ok, failed, cancelled
    }

    /// Ends `state` with "kind=<kind>".
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState, _ kind: Kind) {
        signposter.endInterval(name, state, "kind=\(kind.rawValue, privacy: .public)")
    }

    /// Ends `state` with "kind=<kind> bytes=<bytes>".
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState, _ kind: Kind, bytes: Int) {
        signposter.endInterval(name, state, "kind=\(kind.rawValue, privacy: .public) bytes=\(bytes, privacy: .public)")
    }
}
