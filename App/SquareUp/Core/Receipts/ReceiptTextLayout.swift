import Foundation

/// One visual row of a receipt: regions that share a baseline, left to right.
nonisolated struct ReceiptTextLine: Hashable, Sendable {
    let pageID: ReceiptAssetID
    let pageIndex: Int
    let regions: [RecognizedRegion]

    var text: String { regions.map(\.normalizedText).joined(separator: " ") }
    var bounds: ReceiptRect { regions.dropFirst().reduce(regions[0].bounds) { $0.union($1.bounds) } }
    var regionIDs: [ReceiptRegionID] { regions.map(\.id) }
    /// The weakest region decides how much to trust the row.
    var confidence: Double { regions.map(\.confidence).min() ?? 0 }
}

/// Groups recognized regions into rows using geometry (milestone 3 §6.3 "horizontal and
/// vertical alignment"; §17.2 "observation ordering and row grouping").
///
/// Regions on the same page join a row when their vertical centres are within half a typical
/// text height of the row's centre, or when they overlap vertically by at least half the shorter
/// height. Rows are ordered top to bottom; regions within a row left to right. Deterministic for
/// any input order.
nonisolated enum ReceiptTextLayout {
    static func lines(from regions: [RecognizedRegion], pageOrder: [ReceiptAssetID]) -> [ReceiptTextLine] {
        var result: [ReceiptTextLine] = []
        for (pageIndex, pageID) in pageOrder.enumerated() {
            let pageRegions = regions
                .filter { $0.pageID == pageID && !$0.normalizedText.isEmpty }
                .sorted { lhs, rhs in
                    if lhs.bounds.midY != rhs.bounds.midY { return lhs.bounds.midY < rhs.bounds.midY }
                    if lhs.bounds.x != rhs.bounds.x { return lhs.bounds.x < rhs.bounds.x }
                    return lhs.readingOrder < rhs.readingOrder
                }
            guard !pageRegions.isEmpty else { continue }
            let heights = pageRegions.map(\.bounds.height).sorted()
            let typicalHeight = heights[heights.count / 2]
            var rows: [[RecognizedRegion]] = []
            for region in pageRegions {
                if var row = rows.last, belongs(region, to: row, typicalHeight: typicalHeight) {
                    row.append(region)
                    rows[rows.count - 1] = row
                } else {
                    rows.append([region])
                }
            }
            for row in rows {
                let ordered = row.sorted { lhs, rhs in
                    lhs.bounds.x == rhs.bounds.x ? lhs.readingOrder < rhs.readingOrder : lhs.bounds.x < rhs.bounds.x
                }
                result.append(ReceiptTextLine(pageID: pageID, pageIndex: pageIndex, regions: ordered))
            }
        }
        return result
    }

    private static func belongs(_ region: RecognizedRegion, to row: [RecognizedRegion], typicalHeight: Double) -> Bool {
        let rowBounds = row.dropFirst().reduce(row[0].bounds) { $0.union($1.bounds) }
        let rowCentre = row.map(\.bounds.midY).reduce(0, +) / Double(row.count)
        // A region already overlapping horizontally with the row is a new line (stacked text).
        if row.contains(where: { $0.bounds.x < region.bounds.maxX && region.bounds.x < $0.bounds.maxX }) { return false }
        if abs(region.bounds.midY - rowCentre) <= typicalHeight * 0.5 { return true }
        return region.bounds.verticalOverlap(with: rowBounds) >= 0.5 && region.bounds.height <= typicalHeight * 2
    }
}

/// Deterministic identifiers derived from a seed, so structuring the same input twice produces
/// the same item and charge identifiers (tests and audit comparisons rely on this).
nonisolated enum DerivedID {
    /// Unique per salt for a given seed: the salt is XOR-ed into the last six bytes (a bijection).
    static func make(_ seed: UUID, _ salt: Int) -> UUID {
        var bytes = seed.uuid
        let value = UInt64(truncatingIfNeeded: salt)
        withUnsafeMutableBytes(of: &bytes) { buffer in
            for offset in 0..<6 {
                buffer[10 + offset] ^= UInt8(truncatingIfNeeded: value >> UInt64(8 * (5 - offset)))
            }
        }
        return UUID(uuid: bytes)
    }
}
