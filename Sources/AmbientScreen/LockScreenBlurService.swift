import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins

/// Background-thread Gaussian blur for the lock-screen backdrop's
/// album art. Replaces the synchronous CIFilter call that was running
/// on the main thread on every artwork update — that was the source of
/// the rainbow-wheel hang under caffeinate + lock-screen presentations
/// (hundreds of ms of main-thread block per artwork change, stacking
/// when multiple changes arrived close together).
///
/// Two key changes vs the inline cache it replaces:
/// 1. **Async** — the blur runs in a detached Task at userInitiated
///    priority. The view binds to `blurredArtwork` which is published
///    when the result lands.
/// 2. **Cache keyed by byte hash, not NSImage identity** — the
///    MediaRemoteAdapter creates a new `NSImage` instance for every
///    payload, so identity-keyed caches always missed. Hashing the
///    raw bytes (`NowPlayingState.artworkData`) means same album art
///    = same key = cache hit.
///
/// Memory bounded via LRU eviction (`cacheCapacity`).
@MainActor
final class LockScreenBlurService: ObservableObject {
    /// Latest blurred image. Nil while the first blur for the current
    /// artwork is still in flight, or when no artwork is set.
    @Published private(set) var blurredArtwork: NSImage?

    /// Pixel radius used for the Gaussian blur. Halved from the prior
    /// inline value (80pt) because at full-screen wallpaper sizes the
    /// visual difference is marginal but the CIFilter cost scales
    /// roughly linearly with radius. `nonisolated` so the detached
    /// blur Task can read it without a main-actor hop.
    nonisolated static let blurRadius: Double = 40

    /// LRU cap. Eight entries comfortably covers a single album
    /// listening session (one entry per unique album-art) and is short
    /// enough to keep total memory at ~10 MB worst-case.
    private static let cacheCapacity = 8

    private var cache: [Int: NSImage] = [:]
    private var cacheOrder: [Int] = []
    private var lastHash: Int?
    private var inFlight: Task<Void, Never>?

    /// Called whenever the upstream artwork bytes change. Same bytes
    /// = no-op. New bytes = either a cache hit (immediate) or a
    /// background blur task that publishes when complete.
    func update(artworkData: Data?) {
        guard let data = artworkData, data.isEmpty == false else {
            inFlight?.cancel()
            inFlight = nil
            lastHash = nil
            blurredArtwork = nil
            return
        }

        var hasher = Hasher()
        hasher.combine(data)
        let hash = hasher.finalize()

        if hash == lastHash {
            // Already blurred (or currently blurring) these bytes.
            return
        }
        lastHash = hash

        if let cached = cache[hash] {
            touch(hash)
            blurredArtwork = cached
            return
        }

        inFlight?.cancel()
        inFlight = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.blur(bytes: data)
            // Hop back via an instance method on the @MainActor class
            // — avoids the Swift-6 "capture of var self in concurrent
            // code" diagnostic that the inline closure form trips.
            await self?.applyBlurResult(result, hash: hash)
        }
    }

    /// Lands the background blur back on the main actor. If a newer
    /// artwork started blurring while this one was in flight, discard
    /// this result so we don't flicker back to an older image.
    private func applyBlurResult(_ result: NSImage?, hash: Int) {
        guard lastHash == hash else { return }
        if let result {
            store(hash: hash, image: result)
        }
        blurredArtwork = result
        inFlight = nil
    }

    /// Cancel any in-flight work and clear cached images. Called from
    /// the widget controller's teardown when the lock-screen widget is
    /// disabled by the user — keeps memory clean across enable/disable
    /// cycles.
    func stop() {
        inFlight?.cancel()
        inFlight = nil
        lastHash = nil
        blurredArtwork = nil
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func store(hash: Int, image: NSImage) {
        if cache[hash] != nil {
            cacheOrder.removeAll(where: { $0 == hash })
        }
        cache[hash] = image
        cacheOrder.insert(hash, at: 0)
        while cacheOrder.count > Self.cacheCapacity {
            if let evicted = cacheOrder.popLast() {
                cache.removeValue(forKey: evicted)
            }
        }
    }

    private func touch(_ hash: Int) {
        cacheOrder.removeAll(where: { $0 == hash })
        cacheOrder.insert(hash, at: 0)
    }

    /// Pure function — runs off the main actor in a detached Task.
    /// Reads bytes, runs CIFilter, returns the blurred NSImage (or
    /// nil if decoding/blurring failed). `Data` is Sendable.
    nonisolated private static func blur(bytes: Data) -> NSImage? {
        guard let ci = CIImage(data: bytes) else { return nil }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = ci.clampedToExtent()
        filter.radius = Float(blurRadius)
        let ctx = CIContext()
        guard let output = filter.outputImage,
              let cg = ctx.createCGImage(output, from: ci.extent) else { return nil }
        let size = NSSize(width: cg.width, height: cg.height)
        return NSImage(cgImage: cg, size: size)
    }
}
