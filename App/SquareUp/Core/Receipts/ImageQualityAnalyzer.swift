import Foundation

/// Detects blur, darkness, glare, and low contrast from a small grayscale rendering
/// (milestone 3 §5.2 "visible image-quality warning … when detectable").
///
/// Pure arithmetic over 8-bit luminance so it is unit-testable with synthetic images. The
/// thresholds are deliberately conservative: a warning suggests a retake, it never blocks.
nonisolated enum ImageQualityAnalyzer {
    /// The analyzer expects roughly this many pixels on the long edge.
    static let sampleSize = 256

    static func warnings(luminance pixels: [UInt8], width: Int, height: Int) -> [ImageQualityWarning] {
        guard width > 2, height > 2, pixels.count == width * height else { return [] }
        let count = Double(pixels.count)
        var sum = 0.0
        var dark = 0
        var bright = 0
        for value in pixels {
            sum += Double(value)
            if value < 40 { dark += 1 }
            if value > 250 { bright += 1 }
        }
        let mean = sum / count
        var variance = 0.0
        for value in pixels {
            let delta = Double(value) - mean
            variance += delta * delta
        }
        let standardDeviation = (variance / count).squareRoot()

        // Variance of the 4-neighbour Laplacian: low when edges are soft.
        var laplacianSum = 0.0
        var laplacianSquares = 0.0
        var samples = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let centre = Double(pixels[y * width + x]) * 4
                let neighbours = Double(pixels[y * width + x - 1]) + Double(pixels[y * width + x + 1])
                    + Double(pixels[(y - 1) * width + x]) + Double(pixels[(y + 1) * width + x])
                let value = centre - neighbours
                laplacianSum += value
                laplacianSquares += value * value
                samples += 1
            }
        }
        let laplacianMean = laplacianSum / samples
        let sharpness = laplacianSquares / samples - laplacianMean * laplacianMean

        var warnings: [ImageQualityWarning] = []
        if mean < 70 || Double(dark) / count > 0.6 { warnings.append(.tooDark) }
        if Double(bright) / count > 0.35 && standardDeviation < 60 { warnings.append(.overexposed) }
        if standardDeviation < 18 { warnings.append(.lowContrast) }
        if sharpness < 60, standardDeviation >= 18 { warnings.append(.blurry) }
        return warnings
    }

    /// Text touching the image border suggests part of the receipt is outside the frame.
    static func edgeWarning(for regions: [RecognizedRegion]) -> Bool {
        let margin = 0.004
        return regions.contains { $0.bounds.x < margin || $0.bounds.maxX > 1 - margin || $0.bounds.y < margin || $0.bounds.maxY > 1 - margin }
    }
}
