import SwiftUI

@main
struct DartboardDetectorApp: App {
    init() {
        #if DEBUG
        if DemoScenario.current?.screen == .home {
            UserDefaults.standard.set("[\"Alex\",\"Sam\"]", forKey: "setup.players")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

/// Home, then the game as a full-screen cover.
struct AppRootView: View {
    @State private var game: ActiveGame?
    @State private var cameraCheck: CameraCheckRequest?

    var body: some View {
        HomeView(onStart: startGame, onCameraCheck: { cameraCheck = CameraCheckRequest() })
            .fullScreenCover(item: $game) { game in
                GameView(session: game.session, onExit: { self.game = nil },
                         initialPickerSlot: game.pickerSlot, startsWithCameraExpanded: game.expandCamera)
                    .onAppear { game.session.start() }
                    .onDisappear { game.session.stop() }
            }
            .fullScreenCover(item: $cameraCheck) { _ in
                CameraCheckView(makeSource: { DetectionSourceFactory.make() }) { cameraCheck = nil }
            }
            .onAppear(perform: openDemoScenario)
    }

    private func startGame(rules: X01Rules, players: [String]) {
        game = ActiveGame(session: GameSession(rules: rules, players: players, source: DetectionSourceFactory.make()))
    }

    private func openDemoScenario() {
        #if DEBUG
        guard game == nil, let scenario = DemoScenario.current else { return }
        switch scenario.screen {
        case .home:
            break
        case .game:
            game = ActiveGame(session: GameSession(match: scenario.match, source: DetectionSourceFactory.make()),
                              pickerSlot: scenario.openPickerSlot, expandCamera: scenario.expandCamera)
        case .camera:
            cameraCheck = CameraCheckRequest()
        }
        #endif
    }
}

private struct ActiveGame: Identifiable {
    let session: GameSession
    /// DEBUG demo hook: open the dart picker on this slot.
    var pickerSlot: Int?
    var expandCamera = false
    var id: UUID { session.id }
}

private struct CameraCheckRequest: Identifiable {
    let id = UUID()
}
