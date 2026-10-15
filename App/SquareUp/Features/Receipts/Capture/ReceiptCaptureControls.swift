import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import VisionKit

/// VisionKit's document camera: edge detection, perspective correction, retake, crop, and
/// multiple pages are all provided by the system scanner (milestone 3 §5.2).
struct DocumentCameraView: UIViewControllerRepresentable {
    let completion: (Result<[Data], Error>?) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<[Data], Error>?) -> Void

        init(completion: @escaping (Result<[Data], Error>?) -> Void) {
            self.completion = completion
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.92) }
            completion(.success(pages))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            completion(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            completion(.failure(error))
        }
    }
}

/// Camera permission, asked only when the person chooses to scan (§5.2) and explained first.
enum CameraAccess {
    enum State {
        case notDetermined
        case authorized
        case denied
        case unavailable
    }

    static var state: State {
        guard DocumentCameraView.isSupported else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        default: return .denied
        }
    }
}

/// "Scan with Camera" and "Choose from Photos", with permission and failure handling.
/// Returns image data; the caller stores it.
struct ReceiptCaptureControls: View {
    var scanTitle = String(localized: "Scan with Camera")
    var photosTitle = String(localized: "Choose from Photos")
    var allowsMultiplePhotos = true
    let onImages: ([Data], ReceiptImportSource) -> Void

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isShowingCamera = false
    @State private var isExplainingCamera = false
    @State private var isCameraDenied = false
    @State private var message: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: SUSpacing.sm) {
            Button {
                startScanning()
            } label: {
                Label(scanTitle, systemImage: "doc.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.suPrimary)
            .accessibilityIdentifier("receipt.scan")

            PhotosPicker(selection: $photoItems, maxSelectionCount: allowsMultiplePhotos ? 5 : 1, matching: .images, preferredItemEncoding: .current) {
                Label(photosTitle, systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.suSecondary)
            .accessibilityIdentifier("receipt.photos")

            if let message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            DocumentCameraView { result in
                isShowingCamera = false
                switch result {
                case .success(let pages): if !pages.isEmpty { onImages(pages, .camera) }
                case .failure: message = String(localized: "The camera stopped unexpectedly. Try again or choose from Photos.")
                case nil: break
                }
            }
            .ignoresSafeArea()
        }
        .alert(String(localized: "Scan receipts with the camera"), isPresented: $isExplainingCamera) {
            Button(String(localized: "Continue")) { requestCameraAndScan() }
            Button(String(localized: "Not now"), role: .cancel) {}
        } message: {
            Text(String(localized: "Square Up uses the camera only while you scan. Text is read on this iPhone and the image stays here."))
        }
        .alert(String(localized: "Camera access is off"), isPresented: $isCameraDenied) {
            Button(String(localized: "Open Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button(String(localized: "Choose from Photos instead"), role: .cancel) {}
        } message: {
            Text(String(localized: "Turn on camera access for Square Up in Settings, or import a photo of the receipt."))
        }
    }

    private func startScanning() {
        message = nil
        switch CameraAccess.state {
        case .authorized: isShowingCamera = true
        case .notDetermined: isExplainingCamera = true
        case .denied: isCameraDenied = true
        case .unavailable: message = String(localized: "Camera scanning isn't available on this device. Choose a photo instead.")
        }
    }

    private func requestCameraAndScan() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted { isShowingCamera = true } else { isCameraDenied = true }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var images: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) { images.append(data) }
        }
        photoItems = []
        if images.isEmpty {
            message = String(localized: "Those photos couldn't be loaded. Try another image.")
        } else {
            onImages(images, .photos)
        }
    }
}
