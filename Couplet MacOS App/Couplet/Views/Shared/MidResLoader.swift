import Foundation
import AppKit
import ImageIO

// MARK: - MidResLoader

/// On-demand mid-resolution image loader for the lightbox.
///
/// Generates a ~2048px (long edge) JPEG preview from the source file the first
/// time an image is requested, caches it to disk, and returns the result.
/// Subsequent requests for the same imageID return from disk (or memory) without
/// re-generating.
///
/// Cache location: ~/Library/Caches/Conjunct/previews/{imageID}.jpg
///
/// Eviction: count-based LRU. When the cache exceeds 200 files, the oldest
/// (by modification date) are deleted until the count reaches 150.
actor MidResLoader {

    static let shared = MidResLoader()

    private let cacheDir: URL
    private let targetLongEdge: Int = 2048
    private let evictionHighWatermark: Int = 200
    private let evictionTarget: Int = 150

    /// In-flight generation tasks keyed by imageID.
    /// Deduplicates concurrent requests so we don't generate the same file twice.
    private var inFlight: [Int: Task<NSImage?, Never>] = [:]

    private init() {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = caches.appendingPathComponent("Conjunct/previews")
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true
        )
    }

    // MARK: - Public

    /// Returns a mid-res NSImage for `imageID`, generating and caching it if
    /// not already present. Returns nil if the source file cannot be read.
    ///
    /// - Parameters:
    ///   - imageID:    The database ID of the image (used as the cache filename).
    ///   - sourcePath: Full path to the source image file on disk.
    ///   - folderPath: Path of the indexed folder that contains the image.
    ///                 Used to resolve the security-scoped bookmark.
    func image(for imageID: Int, sourcePath: String, folderPath: String) async -> NSImage? {
        // If a task is already running for this imageID, await it directly.
        if let existing = inFlight[imageID] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [weak self] in
            await self?.generate(imageID: imageID, sourcePath: sourcePath, folderPath: folderPath)
        }
        inFlight[imageID] = task
        let result = await task.value
        inFlight.removeValue(forKey: imageID)
        return result
    }

    // MARK: - Private

    private func generate(imageID: Int, sourcePath: String, folderPath: String) async -> NSImage? {
        let cacheFile = cacheDir.appendingPathComponent("\(imageID).jpg")

        // 1. Memory cache (ThumbnailCache is keyed by URL path)
        if let cached = ThumbnailCache.shared.image(for: cacheFile) {
            return cached
        }

        // 2. Disk cache
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: cacheFile)
            }.value
            if let img = loaded {
                ThumbnailCache.shared.store(img, for: cacheFile)
                return img
            }
            // Corrupt cache file — fall through to regenerate
        }

        // 3. Generate from source (requires security-scoped access)
        guard !sourcePath.isEmpty, !folderPath.isEmpty else { return nil }

        let image = await Task.detached(priority: .userInitiated) { [cacheFile, targetLongEdge] in
            // Resolve bookmark and start security-scoped access
            guard let folderURL = FolderBookmarks.resolve(folderPath: folderPath) else { return nil as NSImage? }
            _ = folderURL.startAccessingSecurityScopedResource()
            defer { folderURL.stopAccessingSecurityScopedResource() }

            guard !Task.isCancelled else { return nil }

            // Read into Data before creating the image source.
            // CGImageSourceCreateWithURL triggers IOSurface-backed hardware
            // decoding, which the sandbox blocks — producing noisy
            // "IOSurface creation failed: e00002c2 / CMPhoto" kernel log spam.
            // Reading into Data first forces the software decoder path instead.
            let sourceURL = URL(fileURLWithPath: sourcePath)
            guard let fileData = try? Data(contentsOf: sourceURL) else { return nil }
            guard let src = CGImageSourceCreateWithData(fileData as CFData, nil) else { return nil }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: targetLongEdge,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }

            guard !Task.isCancelled else { return nil }

            // Write JPEG to disk cache
            let dest = CGImageDestinationCreateWithURL(cacheFile as CFURL, "public.jpeg" as CFString, 1, nil)
            if let dest {
                let writeOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
                CGImageDestinationAddImage(dest, cgImage, writeOptions as CFDictionary)
                CGImageDestinationFinalize(dest)
            }

            let size = CGSize(width: cgImage.width, height: cgImage.height)
            let nsImage = NSImage(cgImage: cgImage, size: size)
            return nsImage
        }.value

        if let image {
            ThumbnailCache.shared.store(image, for: cacheFile)
            try? evictIfNeeded()
        }
        return image
    }

    // MARK: - Eviction

    /// Deletes the oldest preview files when the cache exceeds `evictionHighWatermark`.
    private func evictIfNeeded() throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )
        guard contents.count > evictionHighWatermark else { return }

        // Sort oldest first
        let sorted = try contents.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA < dateB
        }

        let toDelete = sorted.prefix(contents.count - evictionTarget)
        for url in toDelete {
            try? fm.removeItem(at: url)
        }
    }
}
