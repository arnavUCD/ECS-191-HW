import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ReceiptAssetError: Error, Equatable, Sendable {
    /// Not an image ImageIO can decode (corrupt file, PDF, etc.).
    case unsupportedImage
    case tooLarge
    case writeFailed
    /// The file is gone (deleted, or never restored after a device restore).
    case missingFile
}

/// Image normalization with ImageIO (milestone 3 §6.1 stage 2). Never touches the original
/// bytes; produces oriented, downsampled variants for recognition, display, and thumbnails.
nonisolated enum ReceiptImageProcessing {
    /// Long edge of the page variant: enough to verify printed text, small enough to OCR quickly.
    static let pageMaxPixel = 3200
    static let thumbnailMaxPixel = 480
    static let maximumBytes = 40 * 1024 * 1024

    struct SourceInfo: Equatable, Sendable {
        let pixelWidth: Int
        let pixelHeight: Int
        /// EXIF orientation 1–8.
        let orientation: Int
        let fileExtension: String
    }

    static func inspect(_ data: Data) throws(ReceiptAssetError) -> SourceInfo {
        guard data.count <= maximumBytes else { throw .tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw .unsupportedImage }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        return SourceInfo(pixelWidth: width, pixelHeight: height, orientation: orientation,
                          fileExtension: type?.preferredFilenameExtension ?? "jpg")
    }

    /// Decodes with the EXIF orientation applied, downsampled so the long edge ≤ `maxPixel`.
    /// Only the downsampled bitmap is ever decoded (§15 "avoid decoding every full-resolution page").
    static func orientedImage(from data: Data, maxPixel: Int) throws(ReceiptAssetError) -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw .unsupportedImage }
        return try orientedImage(from: source, maxPixel: maxPixel)
    }

    static func orientedImage(at url: URL, maxPixel: Int) throws(ReceiptAssetError) -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else { throw .missingFile }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw .unsupportedImage }
        return try orientedImage(from: source, maxPixel: maxPixel)
    }

    private static func orientedImage(from source: CGImageSource, maxPixel: Int) throws(ReceiptAssetError) -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw .unsupportedImage }
        return image
    }

    /// Applies the person's quarter turns (clockwise), then crops in the rotated space.
    static func transformed(_ image: CGImage, quarterTurns: Int, crop: ReceiptRect?) throws(ReceiptAssetError) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        var result = image
        if turns != 0 {
            let swap = turns % 2 == 1
            let width = swap ? image.height : image.width
            let height = swap ? image.width : image.height
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw .unsupportedImage }
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.rotate(by: -CGFloat(turns) * .pi / 2)
            context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                           width: CGFloat(image.width), height: CGFloat(image.height)))
            guard let rotated = context.makeImage() else { throw .unsupportedImage }
            result = rotated
        }
        if let crop = crop?.clamped, crop != .full {
            let rect = CGRect(x: crop.x * Double(result.width), y: crop.y * Double(result.height),
                              width: crop.width * Double(result.width), height: crop.height * Double(result.height)).integral
            guard let cropped = result.cropping(to: rect) else { throw .unsupportedImage }
            result = cropped
        }
        return result
    }

    static func downsampled(_ image: CGImage, maxPixel: Int) throws(ReceiptAssetError) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longEdge)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw .unsupportedImage }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw .unsupportedImage }
        return result
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.85) throws(ReceiptAssetError) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw .writeFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .writeFailed }
        return data as Data
    }

    // MARK: - AI processing image (milestone 5 §4)

    /// Claude's documented high-resolution limits: images beyond them are downscaled by the API,
    /// so sending more pixels costs bandwidth without adding detail.
    static let processingMaxLongEdge = 2576
    static let processingMaxVisualTokens = 4784
    static let processingMaxBytes = 6 * 1024 * 1024
    static let processingQuality = 0.82

    /// The visual-token cost the API documents for an image: ⌈w/28⌉ · ⌈h/28⌉.
    static func visualTokens(width: Int, height: Int) -> Int {
        ((width + 27) / 28) * ((height + 27) / 28)
    }

    /// The largest size within both limits, keeping the aspect ratio.
    static func processingSize(width: Int, height: Int) -> (width: Int, height: Int) {
        var scale = min(1, Double(processingMaxLongEdge) / Double(max(width, height)))
        let pixelBudget = Double(processingMaxVisualTokens * 28 * 28)
        scale = min(scale, (pixelBudget / Double(width * height)).squareRoot())
        var size = (width: max(1, Int(Double(width) * scale)), height: max(1, Int(Double(height) * scale)))
        // Rounding up to 28-px patches can overshoot by a row or column; shrink until it fits.
        while visualTokens(width: size.width, height: size.height) > processingMaxVisualTokens {
            size = (max(1, size.width * 99 / 100), max(1, size.height * 99 / 100))
        }
        return size
    }

    /// A metadata-free JPEG of a page for AI processing. The page variant is already oriented and
    /// cropped; re-encoding a bare `CGImage` writes no EXIF, GPS, TIFF, or maker data.
    static func processingJPEG(at url: URL) throws(ReceiptAssetError) -> Data {
        let page = try orientedImage(at: url, maxPixel: pageMaxPixel)
        let size = processingSize(width: page.width, height: page.height)
        let image = size.width == page.width && size.height == page.height ? page : try downsampled(page, maxPixel: max(size.width, size.height))
        var quality = processingQuality
        var data = try jpegData(image, quality: quality)
        while data.count > processingMaxBytes, quality > 0.5 {
            quality -= 0.1
            data = try jpegData(image, quality: quality)
        }
        guard data.count <= processingMaxBytes else { throw .tooLarge }
        return data
    }

    /// 8-bit luminance at `ImageQualityAnalyzer.sampleSize` for quality analysis.
    static func luminance(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let maxPixel = ImageQualityAnalyzer.sampleSize
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let width = max(3, Int(Double(image.width) * scale))
        let height = max(3, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }
}
