import Foundation
import CoreGraphics
import Accelerate

public struct ColourFeatures: Sendable {
    /// 18 hue × 8 saturation × 8 lightness bins = 1,152 floats, L1-normalised
    public let hslHistogram: [Float]
    /// 6 dominant colours in LAB space: [L0, a0, b0, L1, a1, b1, ...] = 18 floats
    public let dominantPalette: [Float]
}

public enum ColourAnalyser {

    static let hueBins   = 18
    static let satBins   = 8
    static let lightBins = 8
    static let totalHistBins = hueBins * satBins * lightBins  // 1,152

    static let paletteK   = 6
    static let kMeansIter = 20

    static let analysisMaxDimension = 256

    // MARK: - Public entry point

    public static func analyse(image: CGImage) throws -> ColourFeatures {
        let pixels = try extractRGBPixels(from: image, maxDimension: analysisMaxDimension)
        return ColourFeatures(
            hslHistogram: hslHistogram(pixels: pixels),
            dominantPalette: dominantPalette(pixels: pixels, k: paletteK)
        )
    }

    // MARK: - Accent color extraction

    /// Returns the primary accent color of the image as (hue: 0–360°, saturation: 0–1),
    /// or nil when no qualifying accent exists (B&W images, neutral-dominant images).
    ///
    /// The accent color is the hue cluster with the highest prominence (area × mean saturation)
    /// among clusters that cover ≥5% and ≤40% of the image's pixels after excluding pixels
    /// below saturation 0.25. Prominence favours pale-but-widespread colours over
    /// small-but-vivid ones, consistent with the theory in PAIRING_THEORY.md.
    public static func extractAccentColor(image: CGImage) throws -> (hue: Float, saturation: Float)? {
        let pixels = try extractRGBPixels(from: image, maxDimension: analysisMaxDimension)
        return accentColor(from: pixels)
    }

    static func accentColor(from pixels: [(r: Float, g: Float, b: Float)]) -> (hue: Float, saturation: Float)? {
        let total = pixels.count
        guard total > 0 else { return nil }

        let kBins     = 24          // 15° bins covering 0–360°
        let kSatFloor = Float(0.25) // exclude neutrals, greys, near-whites, near-blacks
        let kMinFrac  = Float(0.05) // accent must appear in ≥5% of pixels
        let kMaxFrac  = Float(0.40) // accent must not dominate (≤40%)

        var counts  = [Int](repeating: 0,     count: kBins)
        var satSums = [Float](repeating: 0.0, count: kBins)

        for px in pixels {
            let (h, s, _) = rgbToHSL(r: px.r, g: px.g, b: px.b)
            guard s >= kSatFloor else { continue }
            // h is in [0, 1); map to bin 0–23
            let bin = min(Int(h * Float(kBins)), kBins - 1)
            counts[bin]  += 1
            satSums[bin] += s
        }

        let totalF      = Float(total)
        var bestBin:    Int?  = nil
        var bestScore   = Float(0)
        var bestMeanSat = Float(0)

        for i in 0..<kBins {
            guard counts[i] > 0 else { continue }
            let frac = Float(counts[i]) / totalF
            guard frac >= kMinFrac && frac <= kMaxFrac else { continue }
            let meanSat   = satSums[i] / Float(counts[i])
            // Prominence = area × saturation: rewards pale-but-widespread colors
            // equally with small-but-vivid ones. A pale blue at 30% / s=0.35
            // scores 0.105; a red at 7% / s=0.75 scores 0.053 — the pale blue wins.
            let prominence = frac * meanSat
            if prominence > bestScore {
                bestScore   = prominence
                bestMeanSat = meanSat
                bestBin     = i
            }
        }

        guard let bin = bestBin else { return nil }
        // Bin center in degrees: each bin spans 15°, center is at bin×15° + 7.5°
        let hue = (Float(bin) + 0.5) * (360.0 / Float(kBins))
        return (hue: hue, saturation: bestMeanSat)
    }

    // MARK: - HSL histogram

    static func hslHistogram(pixels: [(r: Float, g: Float, b: Float)]) -> [Float] {
        var hist = [Float](repeating: 0, count: totalHistBins)

        for px in pixels {
            let (h, s, l) = rgbToHSL(r: px.r, g: px.g, b: px.b)
            let hi = min(Int(h * Float(hueBins)),   hueBins   - 1)
            let si = min(Int(s * Float(satBins)),   satBins   - 1)
            let li = min(Int(l * Float(lightBins)), lightBins - 1)
            hist[hi * (satBins * lightBins) + si * lightBins + li] += 1
        }

        let total = Float(pixels.count)
        if total > 0 {
            for i in 0..<totalHistBins { hist[i] /= total }
        }
        return hist
    }

    // MARK: - Dominant palette via k-means in LAB space

    static func dominantPalette(
        pixels: [(r: Float, g: Float, b: Float)],
        k: Int
    ) -> [Float] {
        guard !pixels.isEmpty else { return [Float](repeating: 0, count: k * 3) }

        let lab = pixels.map { rgbToLAB(r: $0.r, g: $0.g, b: $0.b) }

        let step = max(1, lab.count / k)
        var centroids: [(l: Float, a: Float, b: Float)] =
            stride(from: 0, to: lab.count, by: step).prefix(k).map { lab[$0] }
        while centroids.count < k { centroids.append(lab[0]) }

        for _ in 0..<kMeansIter {
            var sums   = [(Float, Float, Float)](repeating: (0, 0, 0), count: k)
            var counts = [Int](repeating: 0, count: k)

            for px in lab {
                var minDist = Float.infinity
                var nearest = 0
                for (ci, c) in centroids.enumerated() {
                    let d = labDist(px, c)
                    if d < minDist { minDist = d; nearest = ci }
                }
                sums[nearest].0 += px.l
                sums[nearest].1 += px.a
                sums[nearest].2 += px.b
                counts[nearest] += 1
            }

            for i in 0..<k where counts[i] > 0 {
                let n = Float(counts[i])
                centroids[i] = (sums[i].0 / n, sums[i].1 / n, sums[i].2 / n)
            }
        }

        return centroids.flatMap { [$0.0, $0.1, $0.2] }
    }

    // MARK: - Colour space conversions

    static func rgbToHSL(r: Float, g: Float, b: Float) -> (h: Float, s: Float, l: Float) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let l = (maxC + minC) / 2

        guard delta > 1e-6 else { return (0, 0, l) }

        let s = l < 0.5
            ? delta / (maxC + minC)
            : delta / (2 - maxC - minC)

        var h: Float
        if maxC == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) / 6
        } else if maxC == g {
            h = ((b - r) / delta + 2) / 6
        } else {
            h = ((r - g) / delta + 4) / 6
        }
        if h < 0 { h += 1 }

        return (h, s, l)
    }

    static func rgbToLAB(r: Float, g: Float, b: Float) -> (l: Float, a: Float, b: Float) {
        func lin(_ c: Float) -> Float {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let lr = lin(r), lg = lin(g), lb = lin(b)

        let xn: Float = 0.95047, yn: Float = 1.0, zn: Float = 1.08883
        let x = (lr * 0.4124 + lg * 0.3576 + lb * 0.1805) / xn
        let y = (lr * 0.2126 + lg * 0.7152 + lb * 0.0722) / yn
        let z = (lr * 0.0193 + lg * 0.1192 + lb * 0.9505) / zn

        func f(_ t: Float) -> Float {
            t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0
        }
        let L = 116 * f(y) - 16
        let A = 500 * (f(x) - f(y))
        let B = 200 * (f(y) - f(z))
        return (L, A, B)
    }

    private static func labDist(
        _ a: (l: Float, a: Float, b: Float),
        _ b: (l: Float, a: Float, b: Float)
    ) -> Float {
        let dl = a.l - b.l
        let da = a.a - b.a
        let db = a.b - b.b
        return sqrt(dl*dl + da*da + db*db)
    }

    // MARK: - Pixel extraction

    static func extractRGBPixels(
        from image: CGImage,
        maxDimension: Int
    ) throws -> [(r: Float, g: Float, b: Float)] {
        let scale = min(1.0, Double(maxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width)  * scale))
        let h = max(1, Int(Double(image.height) * scale))

        var raw = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &raw,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ColourError.contextCreationFailed
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // FIX: replaced stride(...).map { tuple } with an explicit loop.
        // The tuple return type (Float, Float, Float) inside .map caused the
        // Swift compiler's type-checker to time out.
        let pixelCount = w * h
        var result = [(r: Float, g: Float, b: Float)](
            repeating: (0, 0, 0),
            count: pixelCount
        )
        for i in 0..<pixelCount {
            let offset = i * 4
            result[i] = (
                Float(raw[offset])     / 255,
                Float(raw[offset + 1]) / 255,
                Float(raw[offset + 2]) / 255
            )
        }
        return result
    }

    public enum ColourError: Error {
        case contextCreationFailed
    }
}
