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
/// fires with its URL once the picture is in the cache. A file that can't be
/// decoded is not tried again until `removeAll()`.
@MainActor
final class ThumbnailLoader {
    /// Called with the file's URL once its picture is cached.
    var onLoad: ((URL) -> Void)?

    private let maxPixelSize: Int
    private let cache = NSCache<NSString, NSImage>()
    /// Waiting to be decoded, oldest request first.
    private var pending: [URL] = []
    /// Paths pending or being decoded, so a file is queued once.
    private var queued = Set<String>()
    /// Paths that could not be decoded.
    private var failed = Set<String>()
    private var isDecoding = false
    /// Bumped by removeAll, so a decode started before it is thrown away.
    private var generation = 0

    init(maxPixelSize: Int, costLimit: Int) {
        self.maxPixelSize = maxPixelSize
        cache.totalCostLimit = costLimit
    }

    /// The cached picture of `url`, or nil after queueing it for decoding.
    func image(for url: URL) -> NSImage? {
        let path = url.path
        if let image = cache.object(forKey: path as NSString) { return image }
        if !failed.contains(path), queued.insert(path).inserted {
            pending.append(url)
            decodeNext()
        }
        return nil
    }

    /// Forgets every picture, failure and queued file; a decode already
    /// running finishes, but its result is dropped.
    func removeAll() {
        generation += 1
        cache.removeAllObjects()
        pending.removeAll()
        queued.removeAll()
        failed.removeAll()
    }

    private func decodeNext() {
        guard !isDecoding, !pending.isEmpty else { return }
        isDecoding = true
        let url = pending.removeFirst()
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
        isDecoding = false
        if started == generation {
            let path = url.path
            queued.remove(path)
            if let decoded {
                let image = NSImage(cgImage: decoded, size: .zero)
                cache.setObject(image, forKey: path as NSString, cost: decoded.width * decoded.height * 4)
                onLoad?(url)
            } else {
                failed.insert(path)
            }
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
    var isIdleForSelfTest: Bool { !isDecoding && pending.isEmpty }
    /// The cached picture, without queueing anything.
    func cachedImageForSelfTest(_ url: URL) -> NSImage? { cache.object(forKey: url.path as NSString) }
    #endif
}

/// A decoded image crossing back from the background task. CGImage is
/// immutable, so handing it to the main thread is safe.
private struct DecodedImage: @unchecked Sendable {
    let image: CGImage?
}
