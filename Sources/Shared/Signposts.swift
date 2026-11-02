// Signposts.swift
//
// Performance intervals for Instruments (os_signpost) and
// `log stream --signpost`; see "Measuring performance" in the root README.
// They cost next to nothing while nobody records them.
//
// Metadata is counts, sizes and kinds only: never text, queries, paths, URLs
// or bundle IDs of copied items. Numbers are interpolated with
// `privacy: .public`; kinds are literal text in the message (always public),
// written once in `end(_:_:_:)` below, so no string value is ever made public.
// An OSLogMessage must be written at the call that logs it, so a message
// with numbers calls `Signposts.signposter` directly.

import Foundation
import os

enum Signposts {
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "local.launcher",
        category: "performance"
    )

    /// What an interval ended with, logged as literal text.
    enum Kind {
        case text, image, files
        /// A copy carrying a "don't record me" marker.
        case marked
        /// A copy refused (too large, only whitespace, unreadable image).
        case skipped
        /// Nothing to record or show.
        case none
        case ok, failed, cancelled
    }

    /// An interval with no metadata around `body`.
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        try signposter.withIntervalSignpost(name, around: body)
    }

    /// Ends `state` with "kind=<kind>".
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState, _ kind: Kind) {
        switch kind {
        case .text: signposter.endInterval(name, state, "kind=text")
        case .image: signposter.endInterval(name, state, "kind=image")
        case .files: signposter.endInterval(name, state, "kind=files")
        case .marked: signposter.endInterval(name, state, "kind=marked")
        case .skipped: signposter.endInterval(name, state, "kind=skipped")
        case .none: signposter.endInterval(name, state, "kind=none")
        case .ok: signposter.endInterval(name, state, "kind=ok")
        case .failed: signposter.endInterval(name, state, "kind=failed")
        case .cancelled: signposter.endInterval(name, state, "kind=cancelled")
        }
    }

    /// Ends `state` with "kind=<kind> bytes=<bytes>".
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState, _ kind: Kind, bytes: Int) {
        switch kind {
        case .text: signposter.endInterval(name, state, "kind=text bytes=\(bytes, privacy: .public)")
        case .image: signposter.endInterval(name, state, "kind=image bytes=\(bytes, privacy: .public)")
        case .files: signposter.endInterval(name, state, "kind=files bytes=\(bytes, privacy: .public)")
        case .marked: signposter.endInterval(name, state, "kind=marked bytes=\(bytes, privacy: .public)")
        case .skipped: signposter.endInterval(name, state, "kind=skipped bytes=\(bytes, privacy: .public)")
        case .none: signposter.endInterval(name, state, "kind=none bytes=\(bytes, privacy: .public)")
        case .ok: signposter.endInterval(name, state, "kind=ok bytes=\(bytes, privacy: .public)")
        case .failed: signposter.endInterval(name, state, "kind=failed bytes=\(bytes, privacy: .public)")
        case .cancelled: signposter.endInterval(name, state, "kind=cancelled bytes=\(bytes, privacy: .public)")
        }
    }
}
