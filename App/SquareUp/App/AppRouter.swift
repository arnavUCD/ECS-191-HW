import Foundation
import Observation
import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case home
    case groups
    /// Not a destination: selecting it presents the expense composer.
    case add
    case activity
    case profile
}

enum AppRoute: Hashable {
    case group(GroupID)
    /// The optimized settlement plan for a group (milestone 2.3).
    case settlePlan(GroupID)
    /// Full expense detail with history (milestone 2.2).
    case expense(ExpenseID)
    /// Choose how to pay a recipient in a group (milestone 2.5).
    case pay(groupID: GroupID, recipientID: MemberID)
    /// One payment attempt's status, confirmation, and history (milestone 2.6).
    case paymentAttempt(PaymentAttemptID)
    /// "How friends pay you" (milestone 2.4).
    case paymentProfile
}

/// What the composer should open with.
struct ComposerRequest: Identifiable, Equatable {
    enum Mode: Equatable {
        case manual
        case quickEntry
    }

    let id = UUID()
    var groupID: GroupID?
    var mode: Mode = .manual
    /// Set to edit an existing expense from its saved values.
    var editingExpenseID: ExpenseID?
}

/// What the receipt flow (milestone 3) opens with.
struct ReceiptFlowRequest: Identifiable, Equatable {
    enum Start: Equatable {
        /// Capture or import a new receipt, optionally for a preselected group.
        case new(groupID: GroupID?)
        /// Continue a saved draft or an open room.
        case resume(ReceiptRoomID)
        /// A receipt posted into a shared group, for its people to claim and review.
        case groupReceipt(GroupID, ReceiptRoomID)
    }

    let id = UUID()
    var start: Start
}

/// Deep links: `squp://home`, `squp://groups`, `squp://group/<uuid>`, `squp://add[?group=<uuid>]`,
/// `squp://scan[?group=<uuid>]`, `squp://activity`, `squp://profile`. Invitations
/// (`squp://join/<token>`, `https://<server>/r/<token>`) are handled by `InvitationLink` first.
nonisolated enum DeepLink: Equatable, Sendable {
    case home
    case groups
    case group(GroupID)
    case addExpense(GroupID?)
    case scanReceipt(GroupID?)
    case activity
    case profile

    static let scheme = "squp"

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = url.host()?.lowercased() ?? ""
        let path = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "home", "": return .home
        case "groups": return .groups
        case "group":
            guard let raw = path.first, let id = GroupID(string: raw) else { return nil }
            return .group(id)
        case "add", "scan":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let groupID = query?.first { $0.name == "group" }?.value.flatMap(GroupID.init(string:))
            return host == "add" ? .addExpense(groupID) : .scanReceipt(groupID)
        case "activity": return .activity
        case "profile": return .profile
        default: return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .home: components.host = "home"
        case .groups: components.host = "groups"
        case .group(let id):
            components.host = "group"
            components.path = "/\(id.rawValue.uuidString)"
        case .addExpense(let id):
            components.host = "add"
            if let id { components.queryItems = [URLQueryItem(name: "group", value: id.rawValue.uuidString)] }
        case .scanReceipt(let id):
            components.host = "scan"
            if let id { components.queryItems = [URLQueryItem(name: "group", value: id.rawValue.uuidString)] }
        case .activity: components.host = "activity"
        case .profile: components.host = "profile"
        }
        return components.url!
    }
}

/// Explicit, deep-linkable navigation state for the whole app.
@Observable
final class AppRouter {
    private(set) var selectedTab: AppTab = .home
    var homePath: [AppRoute] = []
    var groupsPath: [AppRoute] = []
    var activityPath: [AppRoute] = []
    var profilePath: [AppRoute] = []

    /// Back to Home with every stack and sheet closed (another account opened, or signed out).
    func reset() {
        selectedTab = .home
        homePath = []
        groupsPath = []
        activityPath = []
        profilePath = []
        composer = nil
        receiptFlow = nil
        groupEditor = nil
    }

    var composer: ComposerRequest?
    var receiptFlow: ReceiptFlowRequest?
    var groupEditor: GroupEditorRequest?

    /// Handles a tab-bar selection. The Add tab presents the composer instead of switching;
    /// re-selecting the current tab pops it to its root (standard iOS behaviour).
    func select(_ tab: AppTab) {
        switch tab {
        case .add:
            presentComposer()
        case selectedTab:
            popToRoot(tab)
        default:
            selectedTab = tab
        }
    }

    func presentComposer(groupID: GroupID? = nil, mode: ComposerRequest.Mode = .manual) {
        composer = ComposerRequest(groupID: groupID, mode: mode)
    }

    func presentComposer(editing expenseID: ExpenseID) {
        composer = ComposerRequest(editingExpenseID: expenseID)
    }

    /// Milestone 3: scan or import a receipt. From a group, that group is preselected.
    func presentReceiptCapture(groupID: GroupID? = nil) {
        receiptFlow = ReceiptFlowRequest(start: .new(groupID: groupID))
    }

    func openReceipt(_ id: ReceiptRoomID) {
        receiptFlow = ReceiptFlowRequest(start: .resume(id))
    }

    /// One of a shared group's pending receipts.
    func openGroupReceipt(_ id: ReceiptRoomID, in groupID: GroupID) {
        receiptFlow = ReceiptFlowRequest(start: .groupReceipt(groupID, id))
    }

    /// After joining from an invitation sheet: let the sheet go, then open the live room.
    func openSharedRoom(_ id: ReceiptRoomID) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            openReceipt(id)
        }
    }

    /// Milestone 7: after joining or sharing from a sheet, let the sheet go, then open the group.
    func openGroupAfterSheet(_ id: GroupID) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            selectedTab = .groups
            groupsPath = [.group(id)]
        }
    }

    /// From inside the composer sheet: close it, then present the receipt flow once it's gone.
    func switchFromComposerToReceipt(groupID: GroupID?) {
        composer = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            presentReceiptCapture(groupID: groupID)
        }
    }

    /// After finalizing: close the receipt flow and show the new expense.
    func finishReceipt(showing expenseID: ExpenseID?) {
        receiptFlow = nil
        guard let expenseID else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            push(.expense(expenseID))
        }
    }

    func showGroup(_ id: GroupID) {
        push(.group(id))
    }

    func showSettlePlan(_ id: GroupID) {
        push(.settlePlan(id))
    }

    /// Pushes onto the selected tab's stack.
    func push(_ route: AppRoute) {
        switch selectedTab {
        case .groups: groupsPath.append(route)
        case .activity: activityPath.append(route)
        case .profile: profilePath.append(route)
        case .home, .add: homePath.append(route)
        }
    }

    func open(_ link: DeepLink) {
        composer = nil
        groupEditor = nil
        receiptFlow = nil
        switch link {
        case .home:
            selectedTab = .home
        case .groups:
            selectedTab = .groups
        case .group(let id):
            selectedTab = .groups
            groupsPath = [.group(id)]
        case .addExpense(let id):
            presentComposer(groupID: id)
        case .scanReceipt(let id):
            presentReceiptCapture(groupID: id)
        case .activity:
            selectedTab = .activity
        case .profile:
            selectedTab = .profile
        }
    }

    private func popToRoot(_ tab: AppTab) {
        switch tab {
        case .home: homePath.removeAll()
        case .groups: groupsPath.removeAll()
        case .activity: activityPath.removeAll()
        case .profile: profilePath.removeAll()
        case .add: break
        }
    }
}

extension EnvironmentValues {
    /// Shared namespace for zoom transitions from group cards to group detail.
    @Entry var groupTransitionNamespace: Namespace.ID?
}
