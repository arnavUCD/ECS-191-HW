import Foundation
@testable import SquareUp

/// A transport whose responses are scripted per test. Records every request.
///
/// The `HTTPTransport` conformance is declared in an extension: declared on the actor itself, an
/// order-dependent compiler inference (default MainActor isolation + a `nonisolated` protocol)
/// sometimes marked the actor `nonisolated` in clean builds (found in milestone 5).
actor ScriptedTransport {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> (Int, Data)
    private(set) var requests: [URLRequest] = []
    private var handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func respond(with handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, data) = try await handler(request, requests.count)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }

    var envelopes: [CommandEnvelope] {
        requests.compactMap { $0.httpBody }.compactMap { try? JSONDecoder().decode(CommandEnvelope.self, from: $0) }
    }
}

extension ScriptedTransport: HTTPTransport {}

/// Lets a test hold a response until it has checked the in-between state.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// A small fictional room (fries 950, pizza 1000, tax 215) in wire form.
enum RemoteFixtures {
    static let roomID = ReceiptRoomID(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    static let host = MemberID(UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
    static let guest = MemberID(UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
    static let fries = ReceiptItemID(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
    static let pizza = ReceiptItemID(UUID(uuidString: "55555555-5555-4555-8555-555555555555")!)
    static let tax = ReceiptChargeID(UUID(uuidString: "66666666-6666-4666-8666-666666666666")!)

    static func id<Tag>(_ value: Identifier<Tag>) -> String { RemoteRoomMapper.id(value) }

    static func room(revision: Int, claims: [ClaimDTO] = [], state: String = "open", viewer: MemberID = guest,
                     disputes: [DisputeDTO] = []) -> RoomDTO {
        RoomDTO(
            roomId: id(roomID), revision: revision, state: state, hostParticipantId: id(host), payerId: id(host),
            receipt: ReceiptDTO(merchant: "Fernwood Supper Club", date: "2026-09-24", currency: "USD", total: 2165, subtotal: nil,
                                items: [ItemDTO(id: id(fries), name: "Truffle Fries", lineTotal: 950, quantity: nil, unitPrice: nil, isRefund: false),
                                        ItemDTO(id: id(pizza), name: "Pizza", lineTotal: 1000, quantity: nil, unitPrice: nil, isRefund: false)],
                                charges: [ChargeDTO(id: id(tax), kind: "tax", label: "Tax", amount: 215, allocation: AllocationRuleDTO(kind: "proportional"))]),
            participants: [
                ParticipantDTO(id: id(host), displayName: "Riley", kind: "host", joinedAt: "2026-09-25T12:00:00.000000Z", removed: false,
                               isClaimedSeat: true, accountBacked: true),
                ParticipantDTO(id: id(guest), displayName: "Sam", kind: "guest", joinedAt: "2026-09-25T12:00:00.000000Z", removed: false,
                               isClaimedSeat: true, accountBacked: false),
            ],
            participantOrder: [id(host), id(guest)], claims: claims, disputes: disputes, reviews: [], needsReview: [],
            payerAcceptsFullReceipt: false,
            allocation: AllocationDTO(receiptTotal: 2165, allocatedTotal: 0, remaining: 2165, isComplete: false, participants: []),
            finalization: nil, assets: [], viewer: ViewerDTO(participantId: id(viewer), isHost: viewer == host),
            updatedAt: "2026-09-25T12:00:00.000000Z"
        )
    }

    static func claim(_ item: ReceiptItemID, by member: MemberID, _ kind: String = "full") -> ClaimDTO {
        ClaimDTO(itemId: id(item), participantId: id(member), mode: ClaimModeDTO(kind: kind))
    }

    static func json(_ value: some Encodable) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }

    static func roomBody(_ room: RoomDTO) -> Data { json(["room": room]) }

    static func commandBody(_ room: RoomDTO, applied: Bool = true, replayed: Bool = false) -> Data {
        struct Body: Encodable {
            let commandId: String
            let applied: Bool
            let replayed: Bool
            let revision: Int
            let room: RoomDTO
        }
        return json(Body(commandId: UUID().uuidString.lowercased(), applied: applied, replayed: replayed, revision: room.revision, room: room))
    }

    static func errorBody(_ code: String, room: RoomDTO? = nil, currentRevision: Int? = nil) -> Data {
        struct Body: Encodable {
            struct Error: Encodable {
                let code: String
                let message: String
                let requestId: String
                let currentRevision: Int?
            }

            let error: Error
            let room: RoomDTO?
        }
        return json(Body(error: .init(code: code, message: "Refused (\(code))", requestId: "test", currentRevision: currentRevision), room: room))
    }

    static let configuration = RemoteConfiguration.make(scheme: "https", host: "squareup.example", authMode: "firebase", firebaseAPIKey: "test-key")!

    /// A guest session: no account needed, so no token requests.
    @MainActor static func session(_ transport: ScriptedTransport) -> RemoteRoomLedger {
        let account = AccountSession(configuration: configuration, transport: transport, keychain: KeychainStore(service: "test.\(UUID())"))
        let api = RoomAPIClient(configuration: configuration, transport: transport, account: account)
        return RemoteRoomLedger(roomID: roomID, caller: .guest("guest-credential"), api: api, now: { DemoScenario.fixedReferenceDate })
    }

    static func path(_ request: URLRequest) -> String { request.url?.path() ?? "" }
}
