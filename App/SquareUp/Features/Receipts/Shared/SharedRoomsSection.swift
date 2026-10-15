import SwiftUI

/// Shared rooms this iPhone hosts or joined, plus joining with a link (milestone 4 §4.3).
struct SharedRoomsSection: View {
    let open: (ReceiptRoomID) -> Void
    @Environment(AppEnvironment.self) private var environment
    @State private var isJoiningWithLink = false

    var body: some View {
        if environment.sharing.isConfigured {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                SUSectionHeader(title: String(localized: "Shared rooms"), actionTitle: String(localized: "Join a receipt")) {
                    isJoiningWithLink = true
                }
                ForEach(environment.sharing.directory.sorted.prefix(8)) { record in
                    SharedRoomRow(record: record) { open(record.roomID) }
                }
                if environment.sharing.directory.records.isEmpty {
                    Text(String(localized: "Rooms you share or join appear here."))
                        .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                }
            }
            .sheet(isPresented: $isJoiningWithLink) { JoinWithLinkSheet() }
        }
    }
}

struct SharedRoomRow: View {
    let record: SharedRoomDirectory.Record
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: SUSpacing.sm) {
                Image(systemName: record.role == .host ? "antenna.radiowaves.left.and.right" : "person.2.wave.2")
                    .font(.title3)
                    .foregroundStyle(SUColor.accent)
                    .frame(width: 40, height: 40)
                    .background(SUColor.accent.opacity(0.14), in: SUShape.control)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title.isEmpty ? String(localized: "Receipt") : record.title)
                        .font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    Text(detail).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
                Spacer(minLength: SUSpacing.xs)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SUColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SUSpacing.sm)
            .suSurface(SUShape.compact)
            .contentShape(SUShape.compact)
        }
        .buttonStyle(.suPressable)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("receipt.shared")
    }

    private var detail: String {
        let role = record.role == .host ? String(localized: "Hosting") : String(localized: "Joined")
        if record.isTemporary {
            let stage = record.isFinished ? String(localized: "Ended")
                : record.state == .finalized ? String(localized: "Waiting for payments") : String(localized: "Splitting now")
            return [role, stage].joined(separator: " · ")
        }
        var parts = [role, ReceiptLanguage.label(record.state)]
        if record.adoptionProblem != nil { parts.append(String(localized: "Needs you")) }
        return parts.joined(separator: " · ")
    }
}
