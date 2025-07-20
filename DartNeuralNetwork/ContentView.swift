import SwiftUI

// Main view controller that manages the tab-based navigation for the app
struct ContentView: View {
    var body: some View {
        TabView {
            PhotoModeView()
                .tabItem {
                    Label("Photo Mode", systemImage: "camera")
                }
            LiveDetectionTabView()
                .tabItem {
                    Label("Live Detection", systemImage: "video")
                }
            GameSelectionView()
                .tabItem {
                    Label("Play", systemImage: "gamecontroller")
                }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
