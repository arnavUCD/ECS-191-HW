import SwiftUI
import TipKit

/// Contextual education (CLAUDE.md §5.8). Each tip appears once, near the thing it explains.
struct AddExpenseTip: Tip {
    var title: Text { Text("Add an expense from anywhere") }
    var message: Text? {
        Text("Tap \(Image(systemName: "plus")) in the tab bar to record what someone paid. Square Up splits it and updates everyone's balance.")
    }

    var image: Image? { Image(systemName: "plus.circle.fill") }
}

struct QuickEntryTip: Tip {
    var title: Text { Text("Describe it in a sentence") }
    var message: Text? {
        Text("Try “I paid $80 for dinner with Maya and Jordan.” You'll review every field before anything is saved.")
    }

    var image: Image? { Image(systemName: "text.bubble") }
}

enum SquareUpTips {
    static func configure(isUITesting: Bool) {
        do {
            if isUITesting {
                Tips.hideAllTipsForTesting()
            }
            try Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault),
            ])
        } catch {
            // Tips are optional education; failing to configure them never blocks the app.
        }
    }
}
