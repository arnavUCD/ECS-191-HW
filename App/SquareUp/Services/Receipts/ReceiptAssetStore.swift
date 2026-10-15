import CoreGraphics
import CryptoKit
import Foundation
import OSLog

/// Receipt image files (milestone 3 §11 `ReceiptAssetStoring`, §12.1).
///
/// Images are files, never SwiftData blobs. SwiftData keeps `ReceiptAsset` references; this
/// store owns the bytes. All work runs off the main actor.
nonisolated protocol ReceiptAssetStoring: Sendable {
    /// Stores an imported or scanned image and produces its page and thumbnail variants.
    func importImage(_ data: Data, id: ReceiptAssetID, source: ReceiptImportSource, createdAt: Date) async throws -> ReceiptAsset
    /// Re-renders the page and thumbnail after a rotation or crop. The original is untouched.
    func transform(_ asset: ReceiptAsset, quarterTurns: Int, crop: ReceiptRect?) async throws -> ReceiptAsset
    /// A downsampled, oriented image for display.
    func image(named fileName: String, maxPixel: Int) async throws -> CGImage
    func delete(_ assets: [ReceiptAsset]) async
    /// Deletes files no record references, ignoring files newer than `cutoff` (imports in flight).
    @discardableResult
    func removeOrphans(referencedFileNames: Set<String>, olderThan cutoff: Date) async -> Int
    /// Removes every receipt file this store owns (Reset Sample Data). Touches nothing else.
    func removeAll() async
    func fileExists(_ fileName: String) async -> Bool
}

/// The on-device implementation: a dedicated directory in Application Support with complete
/// file protection (unless open) and atomic writes.
actor ReceiptAssetStore: ReceiptAssetStoring {
    nonisolated let directory: URL
    private let fileManager = FileManager.default
    /// Only files matching this pattern are ever deleted by cleanup.
    private static let ownedFilePattern = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.(original\.[a-z0-9]+|page\.jpg|thumb\.jpg)$"#

    init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/Receipts`, created on demand.
    nonisolated static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "Receipts", directoryHint: .isDirectory)
    }

    func importImage(_ data: Data, id: ReceiptAssetID, source: ReceiptImportSource, createdAt: Date) async throws -> ReceiptAsset {
        let info = try ReceiptImageProcessing.inspect(data)
        try ensureDirectory()
        let base = id.rawValue.uuidString
        let originalName = "\(base).original.\(info.fileExtension.lowercased())"
        try write(data, to: originalName)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var asset = ReceiptAsset(
            id: id, originalFileName: originalName, pageFileName: "\(base).page.jpg", thumbnailFileName: "\(base).thumb.jpg",
            pixelWidth: 0, pixelHeight: 0, originalOrientation: info.orientation, rotationQuarterTurns: 0, crop: nil, source: source,
            createdAt: createdAt, fingerprint: fingerprint, qualityWarnings: []
        )
        do {
            asset = try render(asset, original: data)
        } catch {
            try? fileManager.removeItem(at: url(originalName))
            throw error
        }
        if min(info.pixelWidth, info.pixelHeight) < 600 { asset.qualityWarnings.append(.lowResolution) }
        Log.receipts.info("Stored receipt page (\(source.rawValue, privacy: .public))")
        return asset
    }

    func transform(_ asset: ReceiptAsset, quarterTurns: Int, crop: ReceiptRect?) async throws -> ReceiptAsset {
        guard let original = fileManager.contents(atPath: url(asset.originalFileName).path) else { throw ReceiptAssetError.missingFile }
        var updated = asset
        updated.rotationQuarterTurns = ((quarterTurns % 4) + 4) % 4
        updated.crop = crop?.clamped
        let resolution = asset.qualityWarnings.contains(.lowResolution)
        updated = try render(updated, original: original)
        if resolution { updated.qualityWarnings.append(.lowResolution) }
        return updated
    }

    func image(named fileName: String, maxPixel: Int) async throws -> CGImage {
        try ReceiptImageProcessing.orientedImage(at: url(fileName), maxPixel: maxPixel)
    }

    func delete(_ assets: [ReceiptAsset]) async {
        for name in assets.flatMap(\.fileNames) {
            try? fileManager.removeItem(at: url(name))
        }
    }

    @discardableResult
    func removeOrphans(referencedFileNames: Set<String>, olderThan cutoff: Date) async -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where Self.isOwned(name) && !referencedFileNames.contains(name) {
            let fileURL = url(name)
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            if (try? fileManager.removeItem(at: fileURL)) != nil { removed += 1 }
        }
        if removed > 0 { Log.receipts.info("Removed \(removed, privacy: .public) orphaned receipt files") }
        return removed
    }

    func removeAll() async {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where Self.isOwned(name) {
            try? fileManager.removeItem(at: url(name))
        }
    }

    func fileExists(_ fileName: String) async -> Bool {
        fileManager.fileExists(atPath: url(fileName).path)
    }

    // MARK: - Private

    nonisolated static func isOwned(_ fileName: String) -> Bool {
        fileName.range(of: ownedFilePattern, options: .regularExpression) != nil
    }

    private func url(_ fileName: String) -> URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    private func ensureDirectory() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        } catch {
            throw ReceiptAssetError.writeFailed
        }
    }

    private func write(_ data: Data, to fileName: String) throws {
        do {
            try data.write(to: url(fileName), options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            Log.receipts.error("Receipt file write failed: \(String(describing: type(of: error)), privacy: .public)")
            throw ReceiptAssetError.writeFailed
        }
    }

    /// Writes the page and thumbnail variants and measures quality. Temporary bitmaps are released
    /// when this returns (§15 "release temporary image buffers promptly").
    private func render(_ asset: ReceiptAsset, original: Data) throws -> ReceiptAsset {
        var asset = asset
        let oriented = try ReceiptImageProcessing.orientedImage(from: original, maxPixel: ReceiptImageProcessing.pageMaxPixel)
        let page = try ReceiptImageProcessing.transformed(oriented, quarterTurns: asset.rotationQuarterTurns, crop: asset.crop)
        try write(try ReceiptImageProcessing.jpegData(page), to: asset.pageFileName)
        let thumbnail = try ReceiptImageProcessing.downsampled(page, maxPixel: ReceiptImageProcessing.thumbnailMaxPixel)
        try write(try ReceiptImageProcessing.jpegData(thumbnail, quality: 0.75), to: asset.thumbnailFileName)
        asset.pixelWidth = page.width
        asset.pixelHeight = page.height
        if let sample = ReceiptImageProcessing.luminance(page) {
            asset.qualityWarnings = ImageQualityAnalyzer.warnings(luminance: sample.pixels, width: sample.width, height: sample.height)
        }
        return asset
    }
}
