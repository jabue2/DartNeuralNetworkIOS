import SwiftUI

struct LiveDetectionContainerView: View {
    @Binding var annotatedImage: UIImage?
    @Binding var scoreText: String
    
    @StateObject var controller = LiveDartDetectionController()
    
    var body: some View {
        LiveDetectionView(controller: controller, scoreText: $scoreText)
            .onAppear {
                // Restart session when view appears.
                controller.restartSession()
                // Set the callback with explicit parameter types.
                controller.onDetectionUpdate = { (annotatedImage: UIImage, scoreText: String) in
                    DispatchQueue.main.async {
                        self.annotatedImage = annotatedImage
                        self.scoreText = scoreText
                    }
                }
            }
            .onDisappear {
                controller.stopSession()
            }
    }
}
