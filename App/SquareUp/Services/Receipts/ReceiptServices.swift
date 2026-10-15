import Foundation
import OSLog

/// The receipt capabilities the app shell injects: protected file storage and the recognition
/// pipeline. Recognition is always on device; the sample receipt uses prerecorded recognition.
nonisolated struct ReceiptServices: Sendable {
    let directory: URL
    let assets: any ReceiptAssetStoring
    let pipeline: ReceiptPipeline

    init(directory: URL, structurer: any ReceiptStructuring = DeterministicReceiptStructurer(),
         recognizer: any ReceiptRecognizing = VisionReceiptRecognizer(), sampleRecognizer: any ReceiptRecognizing = FixtureReceiptRecognizer()) {
        self.directory = directory
        let store = ReceiptAssetStore(directory: directory)
        assets = store
        pipeline = ReceiptPipeline(
            assets: store, fileURL: { directory.appending(path: $0, directoryHint: .notDirectory) },
            recognizer: recognizer, sampleRecognizer: sampleRecognizer, structurer: structurer
        )
    }

    func fileURL(_ fileName: String) -> URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// A throwaway directory for in-memory stores, previews, and tests.
    static func temporary() -> ReceiptServices {
        ReceiptServices(directory: FileManager.default.temporaryDirectory
            .appending(path: "SquareUpReceipts-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    /// Removes image files that no draft, room, or expense refers to (§12.2 "cleanup must detect
    /// orphaned thumbnails and source images safely"). Recent files are left alone.
    func removeOrphans(referencedBy snapshot: LedgerSnapshot, now: Date) async {
        let referenced = Set(snapshot.receiptRooms.flatMap { $0.receipt.pages.filter { !$0.isRemoved }.flatMap(\.fileNames) })
        await assets.removeOrphans(referencedFileNames: referenced, olderThan: now.addingTimeInterval(-600))
    }
}
