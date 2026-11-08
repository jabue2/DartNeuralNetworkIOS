import SwiftUI
import AVFoundation

struct LiveDetectionView: UIViewControllerRepresentable {
    var controller: LiveDartDetectionController
    @Binding var scoreText: String

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .black

        // Create a container view for the live preview, pinned with Auto Layout.
        let previewView = UIView()
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .black
        previewView.isAccessibilityElement = true
        previewView.accessibilityLabel = "Live camera preview"
        vc.view.addSubview(previewView)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: vc.view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor)
        ])

        // Start the live capture session inside the preview.
        controller.startSession(in: previewView)

        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // No-op: label rendering is handled by SwiftUI outside of this representable.
    }
}
