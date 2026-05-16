import Foundation
import CoreGraphics
import Accelerate

public struct GeometricFeatures: Sendable {
    /// 32-bin directional histogram of edge orientations, L1-normalised
    public let edgeOrientation: [Float]
    /// 4×4 composition grid: 16 brightness values + 16 edge densities = 32 floats
    public let compositionGrid: [Float]
}

public enum GeometricAnalyser {

    static let analysisSize  = 128
    static let orientBins    = 32
    static let gridDivisions = 4

    // MARK: - Public entry point

    public static func analyse(image: CGImage) throws -> GeometricFeatures {
        let grey  = try toGreyscale(image: image, size: analysisSize)
        let edges = sobelEdgeMap(pixels: grey, width: analysisSize, height: analysisSize)
        return GeometricFeatures(
            edgeOrientation: orientationHistogram(
                edges: edges, width: analysisSize, height: analysisSize
            ),
            compositionGrid: compositionGrid(
                grey: grey, edges: edges,
                width: analysisSize, height: analysisSize
            )
        )
    }

    // MARK: - Sobel edge detection

    struct EdgePixel {
        var magnitude: Float
        var angle: Float   // radians, [−π, π]
    }

    static func sobelEdgeMap(
        pixels: [Float],
        width: Int,
        height: Int
    ) -> [EdgePixel] {
        var edges = [EdgePixel](
            repeating: EdgePixel(magnitude: 0, angle: 0),
            count: width * height
        )

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                // FIX: removed alignment whitespace around * operator.
                // Swift's parser treated `y   *width` as a prefix-* expression.
                let tl = pixels[(y-1)*width + (x-1)]
                let tc = pixels[(y-1)*width + x]
                let tr = pixels[(y-1)*width + (x+1)]
                let ml = pixels[y*width + (x-1)]
                let mr = pixels[y*width + (x+1)]
                let bl = pixels[(y+1)*width + (x-1)]
                let bc = pixels[(y+1)*width + x]
                let br = pixels[(y+1)*width + (x+1)]

                let gx: Float = (tr + 2*mr + br) - (tl + 2*ml + bl)
                let gy: Float = (bl + 2*bc + br) - (tl + 2*tc + tr)

                edges[y * width + x] = EdgePixel(
                    magnitude: sqrt(gx*gx + gy*gy),
                    angle: atan2(gy, gx)
                )
            }
        }

        return edges
    }

    // MARK: - Orientation histogram

    static func orientationHistogram(
        edges: [EdgePixel],
        width: Int,
        height: Int,
        magnitudeThreshold: Float = 0.15
    ) -> [Float] {
        var hist = [Float](repeating: 0, count: orientBins)

        for edge in edges {
            guard edge.magnitude > magnitudeThreshold else { continue }
            // Map angle [−π, π] → [0, 1) → bin index
            let normalised = (edge.angle + .pi) / (2 * .pi)
            let bin = min(Int(normalised * Float(orientBins)), orientBins - 1)
            hist[bin] += edge.magnitude
        }

        // L1 normalise
        let sum = hist.reduce(0, +)
        if sum > 0 { for i in 0..<orientBins { hist[i] /= sum } }
        return hist
    }

    // MARK: - Composition grid

    static func compositionGrid(
        grey: [Float],
        edges: [EdgePixel],
        width: Int,
        height: Int
    ) -> [Float] {
        let n = gridDivisions
        let cellW = width  / n
        let cellH = height / n
        let cellPixels = Float(cellW * cellH)

        var brightness  = [Float](repeating: 0, count: n * n)
        var edgeDensity = [Float](repeating: 0, count: n * n)

        for row in 0..<n {
            for col in 0..<n {
                let x0 = col * cellW
                let y0 = row * cellH
                var bSum: Float = 0
                var eSum: Float = 0

                for y in y0..<(y0 + cellH) {
                    for x in x0..<(x0 + cellW) {
                        let idx = y * width + x
                        bSum += grey[idx]
                        eSum += edges[idx].magnitude
                    }
                }

                let cellIdx = row * n + col
                brightness[cellIdx]  = bSum / cellPixels
                edgeDensity[cellIdx] = eSum / cellPixels
            }
        }

        return brightness + edgeDensity  // 32 floats total
    }

    // MARK: - Greyscale conversion

    static func toGreyscale(image: CGImage, size: Int) throws -> [Float] {
        var raw = [UInt8](repeating: 0, count: size * size)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &raw,
            width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw GeometricError.contextCreationFailed
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return raw.map { Float($0) / 255 }
    }

    public enum GeometricError: Error {
        case contextCreationFailed
    }
}
