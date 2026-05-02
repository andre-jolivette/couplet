import Foundation
import CoreGraphics
import ImageIO

/// Computes a 64-bit difference hash (dHash) for perceptual similarity detection.
///
/// dHash algorithm:
///   1. Resize image to 9×8 grayscale
///   2. For each row, compare adjacent pixel pairs (8 comparisons × 8 rows = 64 bits)
///   3. Encode as a 16-character hex string
///
/// Hamming distance between two hashes measures how many bits differ.
/// Threshold guidance:
///   ≤ 6  — near-identical (same shot, minor exposure tweak)
///   ≤ 8  — very similar (same shot, different processing style) ← default
///   ≤ 10 — similar (aggressive crop or tonal shift)
///   > 10 — likely different images
public enum PerceptualHasher {

    static let hashWidth  = 9   // one extra column for pairwise comparisons
    static let hashHeight = 8

    // MARK: - Public API

    /// Returns a 16-character hex string representing the 64-bit dHash.
    public static func dHash(image: CGImage) throws -> String {
        let pixels = try toGreyscale(image: image, width: hashWidth, height: hashHeight)
        var bits: UInt64 = 0
        for row in 0..<hashHeight {
            for col in 0..<(hashWidth - 1) {
                let left  = pixels[row * hashWidth + col]
                let right = pixels[row * hashWidth + col + 1]
                bits = (bits << 1) | (left < right ? 1 : 0)
            }
        }
        return String(format: "%016llx", bits)
    }

    /// Computes dHash directly from a file URL using ImageIO (no CGImage allocation overhead).
    public static func dHash(url: URL) throws -> String {
        guard
            let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                src, 0,
                [
                    kCGImageSourceThumbnailMaxPixelSize: 16,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                ] as CFDictionary
            )
        else {
            throw HashError.imageLoadFailed(url)
        }
        return try dHash(image: image)
    }

    /// Hamming distance between two hex-encoded 64-bit hashes.
    /// Returns the number of differing bits (0 = identical, 64 = completely different).
    public static func hammingDistance(_ a: String, _ b: String) -> Int {
        guard
            let aVal = UInt64(a, radix: 16),
            let bVal = UInt64(b, radix: 16)
        else { return 64 }
        return (aVal ^ bVal).nonzeroBitCount
    }

    /// Returns true if two hashes are within the duplicate threshold.
    public static func areDuplicates(_ a: String, _ b: String, threshold: Int = 8) -> Bool {
        hammingDistance(a, b) <= threshold
    }

    // MARK: - Private

    private static func toGreyscale(image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw HashError.contextCreationFailed
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    public enum HashError: Error, LocalizedError {
        case imageLoadFailed(URL)
        case contextCreationFailed

        public var errorDescription: String? {
            switch self {
            case .imageLoadFailed(let url):
                return "Could not load image for hashing: \(url.lastPathComponent)"
            case .contextCreationFailed:
                return "Could not create grayscale context for hashing"
            }
        }
    }
}
