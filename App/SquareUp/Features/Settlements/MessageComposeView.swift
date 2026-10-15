import MessageUI
import SwiftUI

/// The standard Messages composer, addressed and pre-written (Apple Cash handoff).
///
/// Apple exposes no public API to choose Apple Cash, insert its amount, send it, or read its
/// status, so the result here is only whether a message was sent — never whether money moved.
struct MessageComposeView: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    let onFinish: (MessageComposeResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = [recipient]
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void

        init(onFinish: @escaping (MessageComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish(result)
        }
    }
}
