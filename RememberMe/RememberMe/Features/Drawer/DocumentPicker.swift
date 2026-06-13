import SwiftUI
import UniformTypeIdentifiers

/// UIKit-backed document picker. Use instead of SwiftUI's `.fileImporter` when the host
/// view lives inside a `.sheet` — `.fileImporter` silently no-ops in that case because it
/// can't find a presentation context. Attach via `.background(DocumentPicker(...))`.
struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let contentTypes: [UTType]
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        if isPresented, host.presentedViewController == nil {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
            picker.delegate = context.coordinator
            picker.allowsMultipleSelection = false
            DispatchQueue.main.async {
                host.present(picker, animated: true)
            }
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: DocumentPicker
        init(parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.isPresented = false
            if let url = urls.first {
                parent.onPick(url)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}
