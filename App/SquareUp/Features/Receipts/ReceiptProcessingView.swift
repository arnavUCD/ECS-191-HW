import SwiftUI

/// Processing a receipt: only the halftone ring in dusk tones, from choosing a receipt until its
/// review is ready; Back (top left) leaves. The stages (milestone 3 §5.3) aren't shown, but
/// VoiceOver hears them: the ring reads as the current step, and each new stage is announced.
/// Milestone 5: the disclosure appears here the first time a receipt could be sent.
struct ReceiptProcessingView: View {
    let model: ReceiptFlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ReceiptRingScreen(spokenStatus: String(localized: "Reading your receipt. \(stepText): \(stage.title)"), isAnimated: isAnimated)
            .sheet(isPresented: consentBinding, onDismiss: { model.resolveAIConsent(nil) }) {
                ReceiptAIConsentSheet { model.resolveAIConsent($0) }
            }
    }

    private var stage: ReceiptProcessingStage { model.progress?.stage ?? .preparing }

    private var stepText: String {
        let number = (ReceiptProcessingStage.allCases.firstIndex(of: stage) ?? 0) + 1
        var text = String(localized: "Step \(number) of \(ReceiptProcessingStage.allCases.count)")
        if stage == .reading, let progress = model.progress, progress.pageCount > 1 {
            text += " · " + String(localized: "Page \(min(progress.completedPages + 1, progress.pageCount)) of \(progress.pageCount)")
        }
        return text
    }

    private var consentBinding: Binding<Bool> {
        Binding(get: { model.isAskingForAIConsent }, set: { if !$0 { model.resolveAIConsent(nil) } })
    }

    private var isAnimated: Bool { model.environment.allowsAmbientAnimation && !reduceMotion }
}

/// The halftone ring alone, centred on black. Shared by importing photos and processing, so the
/// ring runs unbroken from choosing a receipt until its review is ready (its motion follows the
/// clock, so changing screens doesn't restart it). VoiceOver reads `spokenStatus`.
struct ReceiptRingScreen: View {
    let spokenStatus: String
    let isAnimated: Bool

    var body: some View {
        GeometryReader { proxy in
            SUHalftoneRing(isAnimated: isAnimated)
                .frame(width: min(proxy.size.width * 0.82, 340))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenStatus)
        .accessibilityIdentifier("receipt.processing")
        .background { Color.black.ignoresSafeArea() }
    }
}
