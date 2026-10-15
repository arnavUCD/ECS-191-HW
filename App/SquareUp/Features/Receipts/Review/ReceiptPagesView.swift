import SwiftUI

nonisolated enum ReceiptPageLanguage {
    static func warning(_ warning: ImageQualityWarning) -> String {
        switch warning {
        case .blurry: String(localized: "This page looks blurry. Retake it if values are hard to read.")
        case .tooDark: String(localized: "This page is dark. Try more light, or check values carefully.")
        case .overexposed: String(localized: "Glare may hide some text. Check values carefully.")
        case .lowContrast: String(localized: "Low contrast — faded text may be misread.")
        case .edgesMissing: String(localized: "Text touches the edge. Part of the receipt may be cut off.")
        case .lowResolution: String(localized: "Low resolution. A closer photo will read better.")
        }
    }

    static func note(_ note: StructuringNote, locale: Locale = .autoupdatingCurrent) -> String? {
        switch note {
        case .taxIncluded(let amount):
            String(localized: "Tax of \(MoneyFormatting.string(amount, locale: locale)) is included in the prices, so it isn't added again.")
        case .blankTip: String(localized: "The tip line was blank. Add a tip only if one was paid.")
        case .multipleTotals(let totals):
            String(localized: "More than one total was printed (\(totals.map { MoneyFormatting.string($0, locale: locale) }.formatted(.list(type: .and)))). Check which one was paid.")
        case .mixedCurrencies: String(localized: "More than one currency appears on this receipt. Choose the one it was paid in.")
        case .noText: nil
        case .noPricedLines: String(localized: "Text was found, but no priced lines. Add the items yourself.")
        }
    }
}

/// Page-level editing (milestone 3 §5.4, M3.1 exit condition): rotate, crop, replace or rescan,
/// add, reorder, and remove pages — each with an accessible, non-gesture control.
struct ReceiptPagesView: View {
    let flow: ReceiptFlowModel
    let review: ReceiptReviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var croppingPage: ReceiptAsset?
    @State private var replacingPage: ReceiptAsset?
    @State private var working = false
    @State private var message: String?
    @State private var changedImages = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(review.draft.activePages.enumerated()), id: \.element.id) { index, page in
                    Section(String(localized: "Page \(index + 1)")) {
                        ReceiptImageView(asset: page, variant: .thumbnail)
                            .frame(height: 180)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                        ForEach(page.qualityWarnings, id: \.self) { warning in
                            Label(ReceiptPageLanguage.warning(warning), systemImage: "exclamationmark.triangle").foregroundStyle(SUColor.warning)
                        }
                        HStack {
                            Button(String(localized: "Rotate left"), systemImage: "rotate.left") { rotate(page, by: -1) }
                            Spacer()
                            Button(String(localized: "Rotate right"), systemImage: "rotate.right") { rotate(page, by: 1) }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderless)
                        Button(String(localized: "Crop"), systemImage: "crop") { croppingPage = page }
                        if page.crop != nil {
                            Button(String(localized: "Undo crop"), systemImage: "arrow.uturn.backward") { resetCrop(page) }
                        }
                        Button(String(localized: "Replace or rescan"), systemImage: "arrow.triangle.2.circlepath.camera") { replacingPage = page }
                        if review.draft.activePages.count > 1 {
                            Button(String(localized: "Move earlier"), systemImage: "arrow.up") { review.movePage(page, by: -1) }.disabled(index == 0)
                            Button(String(localized: "Move later"), systemImage: "arrow.down") { review.movePage(page, by: 1) }
                                .disabled(index == review.draft.activePages.count - 1)
                        }
                        Button(String(localized: "Remove page"), systemImage: "trash", role: .destructive) { remove(page) }
                    }
                    .suListRows()
                }
                Section(String(localized: "Add pages")) {
                    ReceiptCaptureControls(scanTitle: String(localized: "Scan more pages"), photosTitle: String(localized: "Add from Photos")) { images, source in
                        add(images, source)
                    }
                    .listRowBackground(Color.clear)
                }
                .suListRows()
                if let message {
                    Section { Label(message, systemImage: "info.circle") }
                        .suListRows()
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .disabled(working)
            .overlay { if working { ProgressView() } }
            .navigationTitle(String(localized: "Pages"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        dismiss()
                        if changedImages {
                            Task {
                                if let room = flow.room { await flow.run(review.saveCommand(for: room)) }
                                flow.recognize()
                            }
                        }
                    }
                }
            }
            .sheet(item: $croppingPage) { page in
                ReceiptCropView(page: page) { rect in crop(page, rect) }
            }
            .sheet(item: $replacingPage) { page in
                NavigationStack {
                    ReceiptCaptureControls(scanTitle: String(localized: "Rescan this page"), photosTitle: String(localized: "Choose a replacement"),
                                           allowsMultiplePhotos: false) { images, source in
                        replacingPage = nil
                        replace(page, with: images, source)
                    }
                    .padding(SUSpacing.screenMargin)
                    .navigationTitle(String(localized: "Replace page"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { replacingPage = nil } } }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private var assets: any ReceiptAssetStoring { flow.environment.receipts.assets }

    private func rotate(_ page: ReceiptAsset, by turns: Int) {
        perform {
            // Rotating resets the crop: a crop is drawn in the rotated orientation.
            let updated = try await assets.transform(page, quarterTurns: page.rotationQuarterTurns + turns, crop: nil)
            review.replacePage(updated)
        }
    }

    /// The new trim is drawn on the current (possibly already cropped) page, so it nests inside the old crop.
    private func crop(_ page: ReceiptAsset, _ crop: ReceiptRect?) {
        let combined: ReceiptRect? = crop.map { trim in
            guard let existing = page.crop else { return trim }
            return ReceiptRect(x: existing.x + trim.x * existing.width, y: existing.y + trim.y * existing.height,
                               width: trim.width * existing.width, height: trim.height * existing.height)
        }
        perform {
            let updated = try await assets.transform(page, quarterTurns: page.rotationQuarterTurns, crop: combined)
            review.replacePage(updated)
        }
    }

    private func resetCrop(_ page: ReceiptAsset) {
        perform {
            await review.replacePage(try assets.transform(page, quarterTurns: page.rotationQuarterTurns, crop: nil))
        }
    }

    private func replace(_ page: ReceiptAsset, with images: [Data], _ source: ReceiptImportSource) {
        perform {
            let others = review.draft.pages.filter { $0.id != page.id }
            let stored = await flow.storePages(images, source: source, existing: others)
            guard let new = stored.pages.first else {
                message = stored.duplicates > 0 ? String(localized: "That page is already on this receipt.") : nil
                return
            }
            review.swapPage(page, with: new)
            await assets.delete([page])
        }
    }

    private func add(_ images: [Data], _ source: ReceiptImportSource) {
        perform {
            let stored = await flow.storePages(images, source: source, existing: review.draft.pages)
            review.addPages(stored.pages)
            message = stored.duplicates > 0 ? Inflect.string("Skipped ^[\(stored.duplicates) page](inflect: true) already on this receipt.") : nil
        }
    }

    private func remove(_ page: ReceiptAsset) {
        review.removePage(page)
        changedImages = true
        Task { await assets.delete([page]) }
    }

    private func perform(_ body: @escaping () async throws -> Void) {
        working = true
        Task {
            do {
                try await body()
                changedImages = true
            } catch {
                message = String(localized: "That page couldn't be updated. Try again or replace it.")
            }
            working = false
        }
    }
}

/// Cropping with four edge controls — usable by VoiceOver and Voice Control, no dragging needed.
struct ReceiptCropView: View {
    let page: ReceiptAsset
    let apply: (ReceiptRect?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var left = 0.0
    @State private var right = 0.0
    @State private var top = 0.0
    @State private var bottom = 0.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ReceiptImageView(asset: page, variant: .page)
                        .frame(height: 260)
                        .overlay {
                            GeometryReader { proxy in
                                Rectangle()
                                    .strokeBorder(SUColor.accent, lineWidth: 2)
                                    .frame(width: proxy.size.width * (1 - left - right), height: proxy.size.height * (1 - top - bottom))
                                    .offset(x: proxy.size.width * left, y: proxy.size.height * top)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text(String(localized: "Trim the edges so only the receipt remains. The original photo is kept."))
                }
                .suListRows()
                Section {
                    edge(String(localized: "Trim left"), $left)
                    edge(String(localized: "Trim right"), $right)
                    edge(String(localized: "Trim top"), $top)
                    edge(String(localized: "Trim bottom"), $bottom)
                }
                .suListRows()
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Crop page"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Apply")) {
                        let rect = ReceiptRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom)
                        apply(rect == .full ? nil : rect.clamped)
                        dismiss()
                    }
                }
            }
        }
    }

    private func edge(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Slider(value: value, in: 0...0.4, step: 0.01) { Text(title) }
                .accessibilityValue(Text(value.wrappedValue, format: .percent.precision(.fractionLength(0))))
        }
    }
}
