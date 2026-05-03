import SwiftUI
import AppKit

// MARK: - Shared image cache

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private init() {
        cache.countLimit = 150
        cache.totalCostLimit = 150 * 1024 * 1024
    }
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }
    func store(_ image: NSImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url.path as NSString, cost: cost)
    }
}

// MARK: - Load throttle

private actor LoadThrottle {
    static let shared = LoadThrottle()
    private var active = 0
    private let max = 4
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active < max { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }
    func release() {
        active -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

// MARK: - ThumbnailView

/// Loads and caches a thumbnail from disk.
/// Uses `.task(id: url)` so the load always re-runs when the URL changes —
/// this prevents LazyHStack view recycling from showing stale images in the
/// wrong filmstrip tile.
struct ThumbnailView: View {

    let url: URL?
    var fallbackColor: NSColor = .darkGray
    var contentMode: ContentMode = .fill

    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color(white: 0.15))
            }
        }
        .clipped()   // prevent fill-mode images from rendering outside allocated frame
        .task(id: url) {
            await load(url: url)
        }
    }

    private func load(url: URL?) async {
        // Clear stale image immediately so the fallback shows during load
        image = nil

        guard let url else { return }

        // Return immediately if cached
        if let cached = ThumbnailCache.shared.image(for: url) {
            image = cached
            return
        }

        await LoadThrottle.shared.acquire()
        defer { Task { await LoadThrottle.shared.release() } }

        // Check cancellation before hitting disk
        guard !Task.isCancelled else { return }

        let loaded = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value

        guard !Task.isCancelled else { return }

        if let loaded {
            ThumbnailCache.shared.store(loaded, for: url)
            image = loaded
        }
    }
}
