import SwiftUI
import AVFoundation

struct LiveDetectionContainerView: View {
    @Binding var annotatedImage: UIImage?
    @Binding var scoreText: String
    
    @StateObject var controller = LiveDartDetectionController()
    
    var body: some View {
        LiveDetectionView(controller: controller, scoreText: $scoreText)
            .onAppear {
                controller.restartSession()
                controller.onDetectionUpdate = { image, text in
                    // image is UIImage?
                    DispatchQueue.main.async {
                        if let img = image {
                            self.annotatedImage = img   // update only when a snapshot is provided
                        }
                        self.scoreText = text
                    }
                }
            }
            .onDisappear {
                controller.stopSession()
            }
            .task {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized:
                    break
                case .notDetermined:
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                default:
                    break
                }
            }
    }
}
