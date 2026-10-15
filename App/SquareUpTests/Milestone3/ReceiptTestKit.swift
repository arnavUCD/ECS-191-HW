import Foundation
@testable import SquareUp

/// Fictional receipt fixtures expressed as recognized regions (no images, no Vision), so the
/// structurer is tested deterministically (milestone 3 §17.3).
enum ReceiptFixtures {
    static let pageID = ReceiptAssetID(UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!)
    static let seed = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000000")!

    static func page(_ id: ReceiptAssetID = pageID, source: ReceiptImportSource = .photos) -> ReceiptAsset {
        ReceiptAsset(
            id: id, originalFileName: "\(id).original.jpg", pageFileName: "\(id).page.jpg", thumbnailFileName: "\(id).thumb.jpg",
            pixelWidth: 1000, pixelHeight: 2000, originalOrientation: 1, rotationQuarterTurns: 0, crop: nil, source: source,
            createdAt: DemoScenario.fixedReferenceDate, fingerprint: "test", qualityWarnings: []
        )
    }

    /// Rows of (left text, right amount). Each cell becomes its own region, like OCR output.
    static func regions(_ rows: [(String, String?)], page: ReceiptAssetID = pageID, confidence: Double = 1, top: Double = 0.05) -> [RecognizedRegion] {
        var regions: [RecognizedRegion] = []
        for (index, row) in rows.enumerated() {
            let y = top + Double(index) * 0.03
            regions.append(RecognizedRegion(
                id: ReceiptRegionID(DerivedID.make(seed, regions.count + 1 + 1000 * (page == pageID ? 0 : 1))), pageID: page, text: row.0,
                confidence: confidence, bounds: ReceiptRect(x: 0.08, y: y, width: 0.5, height: 0.02), readingOrder: regions.count
            ))
            if let amount = row.1 {
                regions.append(RecognizedRegion(
                    id: ReceiptRegionID(DerivedID.make(seed, regions.count + 1 + 1000 * (page == pageID ? 0 : 1))), pageID: page, text: amount,
                    confidence: confidence, bounds: ReceiptRect(x: 0.8, y: y + 0.001, width: 0.12, height: 0.02), readingOrder: regions.count
                ))
            }
        }
        return regions
    }

    static func propose(_ rows: [(String, String?)], currency: CurrencyCode = .usd) -> ReceiptProposal {
        DeterministicReceiptStructurer.propose(ReceiptStructuringInput(
            pages: [page()], regions: regions(rows), defaultCurrency: currency, captureDate: DemoScenario.fixedReferenceDate,
            idSeed: seed, timeZone: .gmt
        ))
    }

    static func draft(_ rows: [(String, String?)], currency: CurrencyCode = .usd) -> ReceiptDraft {
        var draft = ReceiptDraft.empty(pages: [page()], currency: currency, date: DemoScenario.fixedReferenceDate)
        draft.regions = regions(rows)
        draft = propose(rows, currency: currency).applied(to: draft)
        draft.recognition.status = .completed
        return draft
    }

    /// The sample dinner with the true values (matches the bundled image).
    static let dinner: [(String, String?)] = [
        ("FERNWOOD SUPPER CLUB", nil),
        ("418 Example Ave, Davis CA 95616", nil),
        ("(530) 555-0136", nil),
        ("Table 12 Server: Jo Guests: 4", nil),
        ("09/24/2026 7:42 PM", nil),
        ("1 Truffle Fries", "9.50"),
        ("2 Margherita Pizza @ 8.00", "16.00"),
        ("1 Caesar Salad", "11.25"),
        ("2 Lemonade @ 3.50", "7.00"),
        ("1 Mushroom Risotto", "18.75"),
        ("1 Shared Nachos", "12.00"),
        ("1 Tiramisu", "8.50"),
        ("1 Iced Tea", "3.25"),
        ("SUBTOTAL", "86.25"),
        ("Happy Hour Discount", "-4.00"),
        ("Sales Tax 8.25%", "6.79"),
        ("TOTAL", "89.04"),
        ("Tip", "15.00"),
        ("TOTAL", "104.04"),
        ("VISA ****4821", "104.04"),
        ("AUTH CODE 0A1B2C", nil),
        ("Thank you! Come again", nil),
    ]

    /// The bundled recognition fixture JSON, decoded the way the app does.
    static func bundledRegions() async throws -> [RecognizedRegion] {
        try await FixtureReceiptRecognizer().recognize(page: page(source: .sample), imageURL: URL(fileURLWithPath: "/dev/null"), seed: seed)
    }
}

/// Builds rooms through the real engine.
struct RoomHarness {
    var engine: EngineHarness
    let roomID = ReceiptRoomID(UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000001")!)
    let group = Groups.friday
    let host = People.riley

    init(_ state: LedgerSnapshot = sample()) {
        engine = EngineHarness(state)
    }

    var room: ReceiptRoom { engine.state.room(roomID)! }
    var revision: Int { room.revision }

    @discardableResult
    mutating func run(_ command: ReceiptRoomCommand, as actor: MemberID? = nil) throws(LedgerError) -> LedgerCommandResult {
        try engine.run(.receipt(command), as: actor)
    }

    /// Draft → confirmed (Riley paid) → open with the four Friday Dinner Crew members.
    mutating func openDinner(rows: [(String, String?)] = ReceiptFixtures.dinner, payer: MemberID = People.riley) throws {
        try run(.createDraft(roomID, groupID: group, pages: [ReceiptFixtures.page()], currency: .usd))
        try run(.saveDraft(roomID, expectedRevision: revision, receipt: ReceiptFixtures.draft(rows), groupID: group, payerID: payer))
        try run(.confirmReceipt(roomID, expectedRevision: revision))
        try run(.openRoom(roomID, expectedRevision: revision, participants: [People.riley, People.maya, People.alexMorgan, People.priya]))
    }

    func item(_ name: String) -> ReceiptLineItem { room.receipt.items.first { $0.name.value == name }! }
    func charge(_ kind: ReceiptChargeKind) -> ReceiptCharge { room.receipt.charges.first { $0.kind == kind }! }

    mutating func claim(_ name: String, _ request: ClaimRequest = .mine, as actor: MemberID) throws {
        try run(.claim(roomID, expectedRevision: revision, item: item(name).id, request), as: actor)
    }

    /// Every item claimed: a plausible dinner.
    mutating func claimEverything() throws {
        try claim("Truffle Fries", .share, as: People.riley)
        try claim("Truffle Fries", .share, as: People.maya)
        try claim("Margherita Pizza", as: People.alexMorgan)
        try claim("Caesar Salad", as: People.priya)
        try claim("Lemonade", as: People.maya)
        try claim("Mushroom Risotto", as: People.riley)
        try claim("Shared Nachos", .share, as: People.riley)
        try claim("Shared Nachos", .share, as: People.alexMorgan)
        try claim("Shared Nachos", .share, as: People.priya)
        try claim("Tiramisu", as: People.priya)
        try claim("Iced Tea", as: People.alexMorgan)
    }
}
