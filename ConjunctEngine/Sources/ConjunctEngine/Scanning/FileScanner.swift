import Foundation
import CoreGraphics
import ImageIO

/// Reads DateTimeOriginal from EXIF. Returns nil if not present.
private func exifCaptureDate(url: URL) -> Double? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
          let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
    else { return nil }
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    return fmt.date(from: raw)?.timeIntervalSince1970
}

public struct ScannedFile: Sendable {
    public let url: URL
    public let filename: String
    public let fileFormat: String
    public let contentHash: String
    public let captureDate: Double?   // Unix timestamp from EXIF DateTimeOriginal
    public let colorProfile: String   // "color" or "bw"
}

public actor FileScanner {

    // MARK: - Color profile detection

    /// Returns "bw" if the image is monochromatic, "color" otherwise.
    ///
    /// Three-tier check:
    /// 1. kCGImagePropertyColorModel == "Gray" — file stored as actual grayscale.
    /// 2. ICC profile name contains gray/mono/b&w keywords.
    /// 3. Pixel-level chroma sampling — catches B&W JPEG exports from Lightroom /
    ///    Capture One that are stored as RGB with no colour data (the common case
    ///    for street photographers who shoot colour and convert in post).
    public static func detectColorProfile(url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return "color" }

        // Fast path: file is stored as true grayscale
        if let model = props[kCGImagePropertyColorModel] as? String, model == "Gray" {
            return "bw"
        }

        // ICC profile name heuristic
        if let profile = props[kCGImagePropertyProfileName] as? String {
            let lower = profile.lowercased()
            if lower.contains("gray") || lower.contains("mono") || lower.contains("b&w") {
                return "bw"
            }
        }

        // Pixel-level chroma check for RGB files that are effectively greyscale.
        // Downsamples to 32×32 so the decode is ~4 KB regardless of original size.
        if isEffectivelyGrayscale(src: src) { return "bw" }

        return "color"
    }

    /// Returns true when max per-channel chroma difference across all sampled
    /// pixels is ≤ 15/255.  That threshold absorbs JPEG compression ringing
    /// while still distinguishing even lightly tinted colour images.
    private static func isEffectivelyGrayscale(src: CGImageSource) -> Bool {
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return false }

        let size = 32
        // Draw into a known RGBX layout so we can index bytes safely
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = ctx.data else { return false }
        let px = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        var maxChroma = 0
        for i in stride(from: 0, to: size * size * 4, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let chroma = max(abs(r - g), abs(g - b), abs(r - b))
            if chroma > maxChroma { maxChroma = chroma }
            if maxChroma > 15 { return false } // early exit — clearly colour
        }
        return true
    }

    // MARK: - Supported extensions

    public static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tiff", "tif"
    ]

    private let exclusionPatterns: [String]

    public init(exclusionPatterns: [String] = []) {
        self.exclusionPatterns = exclusionPatterns
    }

    public func scan(
        directory url: URL,
        onProgress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> [ScannedFile] {
        // FIX: NSDirectoryEnumerator.makeIterator() is unavailable in async contexts
        // in Swift 6 mode. Extract the synchronous enumeration into a nonisolated
        // helper so the for-in loop runs entirely outside the async context.
        let fileURLs = try Self.enumerateFiles(in: url, exclusionPatterns: exclusionPatterns)

        var results: [ScannedFile] = []
        for fileURL in fileURLs {
            try Task.checkCancellation()

            let ext = fileURL.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }

            guard
                let attrs = try? fileURL.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey
                ]),
                let fileSize = attrs.fileSize,
                let modDate = attrs.contentModificationDate
            else { continue }

            results.append(ScannedFile(
                url: fileURL,
                filename: fileURL.lastPathComponent,
                fileFormat: fileFormat(for: ext),
                contentHash: "\(fileSize)_\(Int(modDate.timeIntervalSince1970))",
                captureDate: exifCaptureDate(url: fileURL),
                colorProfile: Self.detectColorProfile(url: fileURL)
            ))

            if results.count % 50 == 0 {
                onProgress(results.count)
            }
        }

        onProgress(results.count)
        return results
    }

    // MARK: - Synchronous enumeration (nonisolated, not async)
    // Keeping this as a static synchronous function means NSDirectoryEnumerator
    // is never iterated inside an async context, eliminating the Swift 6 warning.

    private static func enumerateFiles(
        in url: URL,
        exclusionPatterns: [String]
    ) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .isDirectoryKey,
                .isHiddenKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            throw ScanError.directoryNotReadable(url)
        }

        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues?.isDirectory == true {
                if exclusionPatterns.contains(where: { fileURL.path.contains($0) }) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if !exclusionPatterns.contains(where: { fileURL.path.contains($0) }) {
                fileURLs.append(fileURL)
            }
        }
        return fileURLs
    }

    private func fileFormat(for ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "heic", "heif": return "HEIC"
        case "png":          return "PNG"
        case "tiff", "tif":  return "TIFF"
        default:             return ext.uppercased()
        }
    }

    public enum ScanError: Error, LocalizedError {
        case directoryNotReadable(URL)

        public var errorDescription: String? {
            switch self {
            case .directoryNotReadable(let url):
                return "Cannot read directory: \(url.path)"
            }
        }
    }
}
