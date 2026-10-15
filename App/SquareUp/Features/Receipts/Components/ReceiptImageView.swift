import SwiftUI
import UIKit

/// A receipt page loaded off the main actor at display size. Missing files show a designed
/// state instead of a broken image (§16 "receipt image is missing when reopening an expense").
struct ReceiptImageView: View {
    enum Variant {
        case thumbnail
        case page
    }

    let asset: ReceiptAsset
    var variant: Variant = .page
    var contentMode: ContentMode = .fit

    @Environment(AppEnvironment.self) private var environment
    @State private var image: UIImage?
    @State private var isMissing = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if isMissing || asset.isRemoved {
                VStack(spacing: SUSpacing.xs) {
                    Image(systemName: "photo.badge.exclamationmark").font(.title2)
                    Text(asset.isRemoved ? String(localized: "Image removed") : String(localized: "Image unavailable"))
                        .font(SUFont.metadata)
                }
                .foregroundStyle(SUColor.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SUColor.surfaceElevated)
            } else {
                SUColor.surfaceElevated
                ProgressView()
            }
        }
        .task(id: asset) { await load() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.isRemoved ? String(localized: "Receipt image removed") : String(localized: "Receipt image"))
        .accessibilityAddTraits(.isImage)
    }

    private func load() async {
        guard !asset.isRemoved else { return }
        let name = variant == .thumbnail ? asset.thumbnailFileName : asset.pageFileName
        let maxPixel = variant == .thumbnail ? ReceiptImageProcessing.thumbnailMaxPixel : 2400
        do {
            let cgImage = try await environment.receipts.assets.image(named: name, maxPixel: maxPixel)
            image = UIImage(cgImage: cgImage)
            isMissing = false
        } catch {
            image = nil
            isMissing = true
        }
    }
}

/// The page with zoom, pan, and an emphasized evidence region (§5.4 "selecting a field should
/// reveal the corresponding region of the original receipt").
struct ReceiptEvidenceViewer: View {
    let page: ReceiptAsset
    /// Regions on this page to emphasize, in unit coordinates.
    var highlights: [ReceiptRect] = []
    var accessibilityDescription: String

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let fitted = fittedSize(in: proxy.size)
            ZStack {
                ReceiptImageView(asset: page)
                    .frame(width: fitted.width, height: fitted.height)
                    .overlay {
                        // Measured from the image's own frame so boxes stay on the evidence at any size.
                        GeometryReader { geometry in
                            ForEach(Array(highlights.enumerated()), id: \.offset) { _, rect in
                                let box = CGRect(x: rect.x * geometry.size.width - 3, y: rect.y * geometry.size.height - 3,
                                                 width: rect.width * geometry.size.width + 6, height: rect.height * geometry.size.height + 6)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(SUColor.accent.opacity(0.18))
                                    .strokeBorder(SUColor.accent, lineWidth: 2 / max(scale, 1) + 0.5)
                                    .frame(width: box.width, height: box.height)
                                    .position(x: box.midX, y: box.midY)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnify.simultaneously(with: drag))
            .onTapGesture(count: 2) { reset() }
            .onChange(of: highlights) { _, rects in focus(on: rects, fitted: fitted, container: proxy.size) }
            .onAppear { focus(on: highlights, fitted: fitted, container: proxy.size) }
        }
        .background(SUColor.surfaceElevated)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Receipt page"))
        .accessibilityValue(accessibilityDescription)
        .accessibilityHint(String(localized: "Pinch to zoom. Double-tap to reset. Every value is also listed below."))
        .accessibilityAction(named: String(localized: "Zoom in")) { withAnimation { scale = min(scale * 1.5, 5); committedScale = scale } }
        .accessibilityAction(named: String(localized: "Reset zoom")) { reset() }
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        let aspect = CGFloat(max(page.pixelWidth, 1)) / CGFloat(max(page.pixelHeight, 1))
        let width = min(container.width, container.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = min(max(committedScale * value.magnification, 1), 6) }
            .onEnded { _ in committedScale = scale }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: committedOffset.width + value.translation.width, height: committedOffset.height + value.translation.height)
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func reset() {
        withAnimation(reduceMotion ? nil : .snappy) {
            scale = 1
            committedScale = 1
            offset = .zero
            committedOffset = .zero
        }
    }

    /// Zooms to the evidence so the person can compare the value with the printed text.
    private func focus(on rects: [ReceiptRect], fitted: CGSize, container: CGSize) {
        guard let first = rects.first else { return }
        let box = rects.dropFirst().reduce(first) { $0.union($1) }
        let target: CGFloat = 2.2
        let centre = CGPoint(x: box.midX * fitted.width - fitted.width / 2, y: box.midY * fitted.height - fitted.height / 2)
        withAnimation(reduceMotion ? nil : .snappy) {
            scale = target
            committedScale = target
            offset = CGSize(width: -centre.x * target, height: -centre.y * target)
            committedOffset = offset
        }
    }
}
