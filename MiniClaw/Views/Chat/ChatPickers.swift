import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DocumentPickerRepresentable: UIViewControllerRepresentable {
    var onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: true 自动产出沙盒内可访问的副本，避免 security-scoped 资源释放问题。
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = true
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            urls.forEach { onPicked($0) }
        }
    }
}

// MARK: - 相机 / 相册选择器（拍照、图片或视频）

struct ImagePickerRepresentable: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let mediaTypes: [String]
    var onPicked: (URL?, UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = sourceType
        vc.mediaTypes = mediaTypes
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (URL?, UIImage?) -> Void
        init(onPicked: @escaping (URL?, UIImage?) -> Void) { self.onPicked = onPicked }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            defer { picker.dismiss(animated: true) }
            if (info[.mediaType] as? String) == UTType.movie.identifier {
                if let url = info[.mediaURL] as? URL { onPicked(url, nil) }
            } else {
                if let img = info[.originalImage] as? UIImage { onPicked(nil, img) }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - 斜杠命令数据模型

/// 斜杠命令项：每条命令有图标、标题、副标题、以及动作类型。
