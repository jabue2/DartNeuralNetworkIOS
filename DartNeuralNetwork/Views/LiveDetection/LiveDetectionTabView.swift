import SwiftUI

// View that provides real-time detection of dartboards and darts using the device camera
struct LiveDetectionTabView: View {
    // Stores the camera feed with detection annotations overlaid
    @State private var liveAnnotatedImage: UIImage?
    // Displays the current score based on detected dart positions
    @State private var liveScoreText: String = "Score: 0" // default value for visibility

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Live Detection")
                    .font(.largeTitle.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top)

                LiveDetectionContainerView(annotatedImage: $liveAnnotatedImage, scoreText: $liveScoreText)
                    .frame(height: 420)
                    .cornerRadius(12)
                    .shadow(radius: 5)
                    .padding(.horizontal)

                if let liveImage = liveAnnotatedImage {
                    Image(uiImage: liveImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320)
                        .padding(.horizontal)
                        .accessibilityLabel("Latest annotated frame")
                }

                Text(liveScoreText.isEmpty ? "No Score" : liveScoreText)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .padding(.bottom)
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .scale))
                    .animation(.easeInOut(duration: 0.2), value: liveScoreText)

                Spacer(minLength: 12)
            }
            .navigationBarTitle("Live Detection", displayMode: .inline)
        }
    }
}

struct LiveDetectionTabView_Previews: PreviewProvider {
    static var previews: some View {
        LiveDetectionTabView()
    }
}
