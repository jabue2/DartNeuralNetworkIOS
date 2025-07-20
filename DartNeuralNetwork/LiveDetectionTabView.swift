import SwiftUI

// View that provides real-time detection of dartboards and darts using the device camera
struct LiveDetectionTabView: View {
    // Stores the camera feed with detection annotations overlaid
    @State private var liveAnnotatedImage: UIImage?
    // Displays the current score based on detected dart positions
    @State private var liveScoreText: String = "Score: 0" // default value for visibility

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Live Detection")
                        .font(.largeTitle)
                        .bold()
                        .padding(.top)

                    // Use GeometryReader to get the available width, but fix the height to 400.
                    GeometryReader { geometry in
                        let containerWidth = geometry.size.width
                        LiveDetectionContainerView(annotatedImage: $liveAnnotatedImage, scoreText: $liveScoreText)
                            .frame(width: containerWidth, height: 450)
                            .cornerRadius(12)
                            .shadow(radius: 5)
                    }
                    // Set the GeometryReader's height to 400 to match the inner view.
                    .frame(height: 450)
                    .padding(.horizontal)

                    // Optionally show the annotated image if available.
                    if let liveImage = liveAnnotatedImage {
                        Image(uiImage: liveImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 300, maxHeight: 300)
                            .border(Color.gray, width: 1)
                            .padding()
                    }

                    // The liveScore text appears below the video container.
                    Text(liveScoreText.isEmpty ? "No Score" : liveScoreText)
                        .font(.title2)
                        .padding(.bottom, 20)
                }
                .padding()
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
