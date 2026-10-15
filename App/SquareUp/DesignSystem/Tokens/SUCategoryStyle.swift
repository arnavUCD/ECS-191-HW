import SwiftUI

/// Consistent category identity across rows, charts, and filters.
///
/// Uses Apple system colours so light, dark, and increased-contrast variants come for free.
/// Category colour is always paired with its symbol and name.
extension ExpenseCategory {
    var label: String {
        switch self {
        case .food: String(localized: "Food & drink")
        case .groceries: String(localized: "Groceries")
        case .housing: String(localized: "Housing")
        case .utilities: String(localized: "Utilities")
        case .transport: String(localized: "Transport")
        case .travel: String(localized: "Travel")
        case .entertainment: String(localized: "Entertainment")
        case .supplies: String(localized: "Supplies")
        case .other: String(localized: "Other")
        }
    }

    var symbolName: String {
        switch self {
        case .food: "fork.knife"
        case .groceries: "cart.fill"
        case .housing: "house.fill"
        case .utilities: "bolt.fill"
        case .transport: "car.fill"
        case .travel: "airplane"
        case .entertainment: "ticket.fill"
        case .supplies: "shippingbox.fill"
        case .other: "square.grid.2x2.fill"
        }
    }

    var color: Color {
        switch self {
        case .food: .orange
        case .groceries: .green
        case .housing: .blue
        case .utilities: .mint
        case .transport: .teal
        case .travel: .indigo
        case .entertainment: .pink
        case .supplies: .purple
        case .other: .gray
        }
    }
}
