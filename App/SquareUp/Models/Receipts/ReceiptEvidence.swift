import Foundation

typealias ReceiptAssetID = Identifier<ReceiptAsset>
typealias ReceiptRegionID = Identifier<RecognizedRegion>
typealias ReceiptItemID = Identifier<ReceiptLineItem>
typealias ReceiptChargeID = Identifier<ReceiptCharge>
typealias ReceiptRoomID = Identifier<ReceiptRoom>
typealias ReceiptDisputeID = Identifier<ReceiptDispute>

/// Where a receipt page came from.
nonisolated enum ReceiptImportSource: String, Codable, Sendable, CaseIterable {
    case camera
    case photos
    /// PROTOTYPE: the bundled fictional receipt used for demonstrations and UI tests.
    case sample
}

/// A rectangle in unit coordinates (0...1) with a **top-left** origin, relative to the page image
/// that was recognized. Geometry is evidence: it groups text into rows and lets review point back at
/// the source. (Vision's lower-left origin is converted at the framework boundary.)
nonisolated struct ReceiptRect: Hashable, Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = ReceiptRect(x: 0, y: 0, width: 1, height: 1)

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    func union(_ other: ReceiptRect) -> ReceiptRect {
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        return ReceiptRect(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
    }

    /// Clamped to the unit square, with a minimum size so a crop can never collapse.
    var clamped: ReceiptRect {
        let minimum = 0.1
        let width = min(max(width, minimum), 1)
        let height = min(max(height, minimum), 1)
        return ReceiptRect(x: min(max(x, 0), 1 - width), y: min(max(y, 0), 1 - height), width: width, height: height)
    }

    /// Vertical overlap with another rectangle as a fraction of the shorter height.
    func verticalOverlap(with other: ReceiptRect) -> Double {
        let overlap = min(maxY, other.maxY) - max(y, other.y)
        let shorter = min(height, other.height)
        guard shorter > 0 else { return 0 }
        return max(0, overlap) / shorter
    }
}

/// Image problems detectable on device. Shown as warnings; never blocks the person.
nonisolated enum ImageQualityWarning: String, Codable, Sendable, CaseIterable {
    case blurry
    case tooDark
    case overexposed
    case lowContrast
    case edgesMissing
    case lowResolution
}

/// One receipt page on disk (milestone 3 §10.1). SwiftData stores this reference and metadata;
/// the image bytes live in the app's protected receipt directory.
///
/// Three variants exist per page: the untouched **original** (verification evidence), a
/// **page** image (orientation, rotation, and crop applied; downsampled for recognition and
/// display), and a small **thumbnail**. Page order is the order of `ReceiptDraft.pages`.
nonisolated struct ReceiptAsset: Identifiable, Hashable, Codable, Sendable {
    let id: ReceiptAssetID
    var originalFileName: String
    var pageFileName: String
    var thumbnailFileName: String
    /// Pixel size of the page variant.
    var pixelWidth: Int
    var pixelHeight: Int
    /// EXIF orientation of the original (1–8), applied when the page variant is produced.
    var originalOrientation: Int
    /// Additional clockwise quarter turns chosen by the person (0–3).
    var rotationQuarterTurns: Int
    /// Crop in the oriented original's unit space. `nil` = the whole image.
    var crop: ReceiptRect?
    var source: ReceiptImportSource
    var createdAt: Date
    /// SHA-256 of the original bytes, for duplicate-page detection.
    var fingerprint: String
    var qualityWarnings: [ImageQualityWarning]
    /// Set when the person removed the image files (the allocation record remains).
    var removedAt: Date?

    var isRemoved: Bool { removedAt != nil }
    var fileNames: [String] { [originalFileName, pageFileName, thumbnailFileName] }
}

/// One piece of recognized text with its geometry (milestone 3 §10.2). Framework-neutral:
/// Vision types never cross into the domain.
nonisolated struct RecognizedRegion: Identifiable, Hashable, Codable, Sendable {
    let id: ReceiptRegionID
    let pageID: ReceiptAssetID
    /// Exactly what the recognizer returned.
    let text: String
    /// Whitespace-collapsed, typographic marks normalized; what the structurer reads.
    let normalizedText: String
    /// 0...1 as reported by the recognizer. Used only as a ranking signal, never shown as a number.
    let confidence: Double
    let bounds: ReceiptRect
    /// Other candidate readings, best first.
    let alternatives: [String]
    /// Stable order within the page (top-to-bottom, then left-to-right).
    let readingOrder: Int

    init(
        id: ReceiptRegionID, pageID: ReceiptAssetID, text: String, confidence: Double, bounds: ReceiptRect,
        alternatives: [String] = [], readingOrder: Int
    ) {
        self.id = id
        self.pageID = pageID
        self.text = text
        normalizedText = Self.normalize(text)
        self.confidence = confidence
        self.bounds = bounds
        self.alternatives = alternatives
        self.readingOrder = readingOrder
    }

    static func normalize(_ text: String) -> String {
        let replaced = text
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        return replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// How much attention a value needs, expressed as an action (milestone 3 §6.5).
nonisolated enum ReceiptAttention: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Consistent value with strong evidence.
    case looksGood = 0
    /// Ambiguous recognition or weak evidence.
    case check = 1
    /// Invalid value or a math conflict.
    case needsResolution = 2

    static func < (lhs: ReceiptAttention, rhs: ReceiptAttention) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why a value has its attention state. Shown in words, never as a percentage.
nonisolated enum AttentionReason: String, Codable, Sendable {
    case strongEvidence
    case lowConfidence
    case notFound
    case multipleCandidates
    case ambiguousFormat
    case quantityMismatch
    case possibleDuplicate
    case invalidValue
    case mathConflict
    case defaultValue
    case confirmedByPerson
    case enteredByPerson
    // Milestone 5: AI proposals checked against on-device evidence.
    /// Worked out from layout or arithmetic rather than read from a printed value.
    case derived
    /// The AI's reading differs from the text Vision read at the cited place.
    case evidenceMismatch
    /// No place on the receipt supports the value.
    case noEvidence
}

/// A structured value with its provenance (milestone 3 §10.4): the current value, what the
/// recognizer originally proposed, why it needs attention, where it came from, and who edited it.
nonisolated struct ReceiptField<Value: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    var value: Value
    /// The machine proposal, kept for audit even after edits.
    let proposed: Value
    var attention: ReceiptAttention
    var reason: AttentionReason
    var sourceRegionIDs: [ReceiptRegionID]
    var editedBy: MemberID?
    var editedAt: Date?

    init(
        _ value: Value, attention: ReceiptAttention = .looksGood, reason: AttentionReason = .strongEvidence,
        sources: [ReceiptRegionID] = []
    ) {
        self.value = value
        proposed = value
        self.attention = attention
        self.reason = reason
        sourceRegionIDs = sources
    }

    /// A value typed by a person with no machine proposal behind it.
    static func entered(_ value: Value, by memberID: MemberID?, at date: Date) -> ReceiptField {
        var field = ReceiptField(value, reason: .enteredByPerson)
        field.editedBy = memberID
        field.editedAt = date
        return field
    }

    var isEdited: Bool { editedBy != nil }

    /// Records a person's edit (or confirmation of the existing value).
    mutating func edit(_ newValue: Value, by memberID: MemberID?, at date: Date) {
        value = newValue
        attention = .looksGood
        reason = proposed == newValue ? .confirmedByPerson : .enteredByPerson
        editedBy = memberID
        editedAt = date
    }
}
