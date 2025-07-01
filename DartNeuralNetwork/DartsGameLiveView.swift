import SwiftUI

struct DartsGameLiveView: View {
    @State private var annotatedImage: UIImage?
    @State private var scoreText: String = ""
    
    // Use StateObject for our controller.
    @StateObject var controller = LiveDartDetectionController()
    
    // Starting game score: set to 301 or 501 as desired.
    var startingScore: Int
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    
                    // Live Detection Container
                    Text("Live Detection")
                        .font(.largeTitle)
                        .bold()
                        .padding(.top)
                    
                    LiveDetectionView(controller: controller, scoreText: $scoreText)
                        .frame(height: 450)
                        .cornerRadius(12)
                        .shadow(radius: 5)
                        .padding(.horizontal)
                    
                    // Annotated Snapshot Section (if available)
                    if let img = annotatedImage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Detected Darts")
                                .font(.headline)
                                .padding(.leading)
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 300)
                                .cornerRadius(8)
                                .padding(.horizontal)
                        }
                    }
                    
                    // Score Display
                    Text(scoreText.isEmpty ? "Waiting for score..." : scoreText)
                        .font(.title)
                        .bold()
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(UIColor.systemGray6))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    
                    Spacer()
                }
                .padding(.vertical)
            }
            .navigationBarTitle("Darts Game", displayMode: .inline)
            .onAppear {
                // Initialize game mode.
                controller.gameMode = startingScore
                controller.gameScore = startingScore
                controller.lastScoreText = "Game started. Score: \(startingScore)"
                controller.restartSession()
                controller.onDetectionUpdate = { (annotated, text) in
                    DispatchQueue.main.async {
                        self.annotatedImage = annotated
                        self.scoreText = text
                    }
                }
            }
            .onDisappear {
                controller.stopSession()
            }
        }
    }
}

struct DartsGameLiveView_Previews: PreviewProvider {
    static var previews: some View {
        DartsGameLiveView(startingScore: 301)
    }
}
