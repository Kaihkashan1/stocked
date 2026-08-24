import SwiftUI
import UIKit

/// Wraps UIImagePickerController for camera capture — PhotosPicker (PhotosUI)
/// only covers the photo library, not live camera capture.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void

        init(onCapture: @escaping (UIImage) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

extension UIImage {
    /// Downscales to at most `maxDimension` on the longest side and encodes
    /// as JPEG — a recipe card/cookbook page stays perfectly legible to
    /// Gemini at this size, and it keeps the upload well under Vercel's
    /// request body limit.
    func recipePhotoJPEGData(maxDimension: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else { return jpegData(compressionQuality: quality) }
        let scale = maxDimension / longestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality)
    }
}
