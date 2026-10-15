import SwiftUI

/// The sync state of a shared group, in words and symbols (never color alone), with the actions
/// the milestone requires: Review latest, Try again, and Discard my change (§7.4, §12, §14).
struct SharedGroupStatusBar: View {
    let ledger: SharedGroupLedger
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            if let state = stateLine {
                Label {
                    Text(state.text).font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                } icon: {
                    Image(systemName: state.symbol).foregroundStyle(state.tone.color)
                        .symbolEffect(.pulse, isActive: state.isActive && !reduceMotion)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sharedGroup.status")
            }
            if let notice = ledger.notice { noticeView(notice) }
            ForEach(ledger.unsent) { change in unsentRow(change) }
            if let error {
                Text(error).font(SUFont.metadata).foregroundStyle(SUColor.negative)
            }
        }
        .onChange(of: ledger.notice) { _, notice in
            guard let notice else { return }
            AccessibilityNotification.Announcement(Self.announcement(for: notice)).post()
        }
    }

    // MARK: State

    private struct StateLine {
        let text: String
        let symbol: String
        let tone: SUTone
        var isActive = false
    }

    private var stateLine: StateLine? {
        func since(_ date: Date?) -> String {
            date.map { String(localized: "showing the copy from \($0.formatted(.relative(presentation: .named)))") } ?? String(localized: "showing the saved copy")
        }
        switch ledger.syncState {
        case .loading:
            return StateLine(text: String(localized: "Loading the group…"), symbol: "arrow.triangle.2.circlepath", tone: .neutral, isActive: true)
        case .synced, .refreshing:
            // A background refresh changes nothing on screen (it made the layout jump); what it finds
            // simply appears.
            return ledger.isArchived
                ? StateLine(text: String(localized: "Archived · read only"), symbol: "archivebox", tone: .neutral)
                : StateLine(text: String(localized: "Shared · up to date"), symbol: "checkmark.icloud", tone: .positive)
        case .sending(let count):
            return StateLine(text: Inflect.string("Sending ^[\(count) change](inflect: true)…"), symbol: "arrow.up.circle", tone: .informational,
                             isActive: true)
        case .offline(let date):
            return StateLine(text: String(localized: "Offline · \(since(date)). Nothing new can be confirmed until you're back online."),
                             symbol: "icloud.slash", tone: .warning)
        case .sessionEnded:
            return StateLine(text: String(localized: "Signed out · sign in again to make changes. Nothing you entered was lost."),
                             symbol: "person.crop.circle.badge.exclamationmark", tone: .warning)
        case .accessEnded:
            return StateLine(text: String(localized: "You're no longer in this group."), symbol: "person.crop.circle.badge.xmark", tone: .negative)
        }
    }

    // MARK: Notices

    @ViewBuilder
    private func noticeView(_ notice: SharedGroupLedger.Notice) -> some View {
        switch notice {
        case .conflict(let summary):
            SUConfirmationBanner(
                title: String(localized: "Someone changed the group first"),
                message: String(localized: "“\(summary)” wasn't saved. The latest is showing — review it, then try again."),
                systemImage: "arrow.triangle.merge", tone: .warning,
                actionTitle: String(localized: "Review latest")
            ) { ledger.dismissNotice() }
                .accessibilityIdentifier("sharedGroup.conflict")
        case .expenseChanged(let expenseID):
            SUConfirmationBanner(
                title: String(localized: "Someone changed this expense"),
                message: String(localized: "Your edit wasn't saved and is still in the editor. Review the latest version, then save again or discard your change."),
                systemImage: "arrow.triangle.merge", tone: .warning,
                actionTitle: String(localized: "Review latest")
            ) {
                ledger.dismissNotice()
                router.push(.expense(expenseID))
            }
            .accessibilityIdentifier("sharedGroup.expenseConflict")
        case .refused(let summary, let message):
            SUConfirmationBanner(
                title: String(localized: "“\(summary)” wasn't saved"), message: message,
                systemImage: "exclamationmark.triangle.fill", tone: .negative,
                actionTitle: String(localized: "Discard my change")
            ) {
                if let change = ledger.unsent.first(where: { $0.summary == summary && $0.refusal != nil }) { ledger.discard(change) }
            }
        case .unreadable:
            SUConfirmationBanner(
                title: String(localized: "Couldn't read the latest changes"),
                message: String(localized: "Showing the last version that added up on this iPhone. Nothing was changed."),
                systemImage: "exclamationmark.icloud", tone: .warning,
                actionTitle: String(localized: "Try again")
            ) { Task { try? await ledger.refresh() } }
        case .connectionRequired(let summary):
            SUConfirmationBanner(
                title: String(localized: "Connection required"),
                message: String(localized: "“\(summary)” needs the server's answer, so nothing is confirmed yet. Try again when you're online."),
                systemImage: "wifi.exclamationmark", tone: .warning,
                actionTitle: String(localized: "Try again")
            ) {
                Task {
                    isWorking = true
                    defer { isWorking = false }
                    do {
                        try await ledger.retryUnconfirmed()
                        error = nil
                    } catch {
                        self.error = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
                    }
                }
            }
            .accessibilityIdentifier("sharedGroup.connectionRequired")
        }
    }

    private func unsentRow(_ change: SharedGroupCache.UnsentChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SUSpacing.sm) {
            Image(systemName: change.refusal == nil ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                .foregroundStyle(change.refusal == nil ? SUColor.warning : SUColor.negative)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.summary).font(SUFont.body).foregroundStyle(SUColor.textPrimary)
                Text(change.refusal ?? String(localized: "Waiting for connection · will send automatically"))
                    .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
            }
            Spacer(minLength: SUSpacing.xs)
            Button(String(localized: "Discard")) { ledger.discard(change) }
                .font(SUFont.supporting)
                .frame(minHeight: 44)
                .accessibilityLabel(String(localized: "Discard my change: \(change.summary)"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sharedGroup.unsent")
    }

    static func announcement(for notice: SharedGroupLedger.Notice) -> String {
        switch notice {
        case .conflict: String(localized: "Someone changed the group first. Your change wasn't saved.")
        case .expenseChanged: String(localized: "Someone changed this expense. Your edit wasn't saved.")
        case .refused(let summary, _): String(localized: "\(summary) wasn't saved.")
        case .unreadable: String(localized: "Couldn't read the latest changes. Showing the last good version.")
        case .connectionRequired: String(localized: "Connection required. Nothing was confirmed.")
        }
    }
}

/// Keeps a shared group in sync while its screens are visible: polling starts on appear, stops in
/// the background, and refreshes on returning to the foreground (§7.3).
struct SharedGroupSyncModifier: ViewModifier {
    let ledger: SharedGroupLedger?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { ledger?.beginCollaborating() }
            .onDisappear { ledger?.endCollaborating() }
            .onChange(of: scenePhase) { _, phase in
                guard let ledger else { return }
                if phase == .active { ledger.startPolling() } else { ledger.stopPolling() }
            }
            .refreshable { try? await ledger?.refresh() }
    }
}

extension View {
    func sharedGroupSync(_ ledger: SharedGroupLedger?) -> some View {
        modifier(SharedGroupSyncModifier(ledger: ledger))
    }
}
