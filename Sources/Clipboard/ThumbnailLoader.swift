// ThumbnailLoader.swift
//
// Downsampled pictures for the clipboard history panel, decoded off the main
// thread. A PNG carries no thumbnail of its own, so even a 96 px row icon
// means decoding the whole image (a 5K screenshot takes a noticeable moment):
// done on the main thread, a few of them froze the panel as it opened.

import Cocoa
import ImageIO

/// Decodes images at one size, one at a time in the background (so a list of
/// screenshots doesn't decode them all at once, each at full size in memory),
/// and keeps the results in a cache costed by decoded size. `image(for:)`
/// answers from the cache or queues the file and returns nil; `onLoad` then
/// fires with the picture, or nil when the file can't be decoded. The newest
/// request goes first, so what is on screen now isn't kept waiting behind
/// rows scrolled past. A file that can't be decoded is not tried again until
/// `forgetFailures()` or `removeAll()`. `keepOnly(_:)` forgets everything
/// about files that left the history, so a cleared image's picture doesn't
/// stay in memory.
@MainActor
final class ThumbnailLoader {
    /// Called with the file's URL and its picture once decoded (also cached),
    /// or nil when it can't be decoded.
    var onLoad: ((URL, NSImage?) -> Void)?

    private let maxPixelSize: Int
    private let cache = NSCache<NSString, NSImage>()
    /// Paths put in `cache` (NSCache can't list its keys). Some may have been
    /// evicted since, which only means removeObject finds nothing.
    private var cachedPaths = Set<String>()
    /// Waiting to be decoded; the last one is decoded next.
    private var pending: [URL] = []
    /// Paths pending or being decoded, so a file is queued once.
    private var queued = Set<String>()
    /// Paths that could not be decoded.
    private var failed = Set<String>()
    /// The path being decoded, if any.
    private var decoding: String?
    /// The running decode's result is to be dropped (keepOnly left it out).
    private var discardsDecoding = false
    /// Bumped by removeAll, so a decode started before it is thrown away.
    private var generation = 0

    init(maxPixelSize: Int, costLimit: Int) {
        self.maxPixelSize = maxPixelSize
        cache.totalCostLimit = costLimit
    }

    /// The cached picture of `url`, or nil after queueing it for decoding
    /// (unless it failed before).
    func image(for url: URL) -> NSImage? {
        let path = url.path
        if let image = cache.object(forKey: path as NSString) { return image }
        // Wanted again (an image copied again) before its dropped decode ended.
        if path == decoding { discardsDecoding = false }
        if !failed.contains(path), queued.insert(path).inserted {
            pending.append(url)
            decodeNext()
        }
        return nil
    }

    /// Whether `url` could not be decoded (so `image(for:)` won't try again).
    func hasFailed(_ url: URL) -> Bool {
        failed.contains(url.path)
    }

    /// Drops the requests still waiting (rows no longer on screen); the
    /// decode already running finishes and is cached.
    func cancelPending() {
        for url in pending { queued.remove(url.path) }
        pending.removeAll()
    }

    /// Lets the files that failed be tried again, in case the failure was
    /// passing (a file being rewritten, a volume waking up).
    func forgetFailures() {
        failed.removeAll()
    }

    /// Forgets every picture, failure and queued file; a decode already
    /// running finishes, but its result is dropped.
    func removeAll() {
        generation += 1
        cache.removeAllObjects()
        cachedPaths.removeAll()
        pending.removeAll()
        queued.removeAll()
        failed.removeAll()
    }

    /// Forgets the pictures, failures and waiting requests of every file not
    /// in `paths` (the files still in the history). A decode already running
    /// for one of them finishes, but its result is dropped.
    func keepOnly(_ paths: Set<String>) {
        for path in cachedPaths.subtracting(paths) {
            cache.removeObject(forKey: path as NSString)
        }
        cachedPaths.formIntersection(paths)
        failed.formIntersection(paths)
        pending.removeAll { !paths.contains($0.path) }
        queued = queued.filter { paths.contains($0) || $0 == decoding }
        if let decoding, !paths.contains(decoding) { discardsDecoding = true }
    }

    private func decodeNext() {
        guard decoding == nil, let url = pending.popLast() else { return }
        decoding = url.path
        let size = maxPixelSize
        let started = generation
        Task {
            let decoded = await Task.detached(priority: .userInitiated) {
                DecodedImage(image: ThumbnailLoader.decode(url, maxPixelSize: size))
            }.value
            self.finish(url, decoded.image, generation: started)
        }
    }

    private func finish(_ url: URL, _ decoded: CGImage?, generation started: Int) {
        decoding = nil
        let discarded = discardsDecoding
        discardsDecoding = false
        if discarded {
            queued.remove(url.path)
        } else if started == generation {
            let path = url.path
            queued.remove(path)
            let image = decoded.map { NSImage(cgImage: $0, size: .zero) }
            if let image, let decoded {
                cache.setObject(image, forKey: path as NSString, cost: decoded.width * decoded.height * 4)
                cachedPaths.insert(path)
            } else {
                failed.insert(path)
            }
            // The picture itself, not a cache lookup: the cache may evict it
            // at any time.
            onLoad?(url, image)
        }
        decodeNext()
    }

    /// Downsampled with ImageIO, so the full-size image is never kept.
    nonisolated private static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    #if SELFTEST
    /// Nothing queued or being decoded.
    var isIdleForSelfTest: Bool { decoding == nil && pending.isEmpty }
    /// The cached picture, without queueing anything.
    func cachedImageForSelfTest(_ url: URL) -> NSImage? { cache.object(forKey: url.path as NSString) }
    #endif
}

/// A decoded image crossing back from the background task. CGImage is
/// immutable, so handing it to the main thread is safe.
private struct DecodedImage: @unchecked Sendable {
    let image: CGImage?
}
