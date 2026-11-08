#if DEBUG
import SwiftUI
import UIKit

/// Scripted stand-in for the camera so every screen can be run in the simulator.
/// Compiled into DEBUG builds only.
///
/// Launch arguments:
///   -demoScenario <name>   see `DemoScenario` (home, live, route, picker, framing, bust,
///                          checkout, summary, searching, aligning, ready, nocamera, camera)
/// Without arguments, simulator DEBUG builds use the `play` script: a random thrower.
@MainActor
final class DemoDetectionSource: ObservableObject, DartDetectionSource {
    struct Script {
        /// Status after the warm-up.
        var status: BoardStatus = .ready
        /// Walk through searching → aligning before `status`.
        var warmUp = false
        /// Darts reported right after start.
        var darts: [DetectedDart] = []
        /// Keep throwing random darts and clearing the board.
        var autoplay = false
    }

    @Published private(set) var status: BoardStatus = .searching {
        didSet { if status != oldValue { onEvent?(.status(status)) } }
    }
    /// Darts currently sticking in the board (drawn in the demo camera view).
    @Published private(set) var boardDarts: [DetectedDart] = []
    var onEvent: ((DetectionEvent) -> Void)?

    private let script: Script
    private var task: Task<Void, Never>?
    private var waitingForRemoval = false
    private lazy var previewHost: PreviewHostView = {
        let host = PreviewHostView()
        let controller = UIHostingController(rootView: DemoCameraScene(source: self))
        controller.view.backgroundColor = .black
        hosting = controller
        host.addSubview(controller.view)
        return host
    }()
    private var hosting: UIHostingController<DemoCameraScene>?

    init(script: Script) {
        self.script = script
        self.status = script.warmUp ? .searching : script.status
    }

    /// The demo source for this launch, or nil to use the real camera.
    static func fromLaunchArguments() -> DemoDetectionSource? {
        if let scenario = DemoScenario.current {
            return scenario.usesCamera ? nil : DemoDetectionSource(script: scenario.script)
        }
        #if targetEnvironment(simulator)
        return DemoDetectionSource(script: Script(warmUp: true, autoplay: true))
        #else
        return nil
        #endif
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func endVisit() {
        waitingForRemoval = true
    }

    func resumeVisit() {
        waitingForRemoval = false
    }

    func reset() {
        // Like the camera: darts still on the board must be pulled before a new game scores.
        waitingForRemoval = !boardDarts.isEmpty
    }

    func makePreviewView() -> UIView { previewHost }

    // MARK: Script

    private func run() async {
        if script.warmUp && status != script.status {
            status = .searching
            guard await pause(0.8) else { return }
            status = .aligning
            guard await pause(0.9) else { return }
        }
        status = script.status
        for dart in script.darts {
            guard await pause(0.35) else { return }
            emit(dart)
        }
        guard script.autoplay else { return }

        while !Task.isCancelled {
            if waitingForRemoval || boardDarts.count >= 3 {
                guard await pause(2.0) else { return }
                boardDarts = []
                waitingForRemoval = false
                onEvent?(.boardCleared)
            } else {
                guard await pause(2.2) else { return }
                if status == .ready, !waitingForRemoval { emit(Self.randomDart()) }
            }
        }
    }

    private func emit(_ dart: DetectedDart) {
        withAnimation(.snappy) { boardDarts.append(dart) }
        onEvent?(.dartDetected(dart))
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled
    }

    /// A throw aimed at treble 20 with a realistic spread.
    nonisolated static func randomDart() -> DetectedDart {
        let aim = BoardGeometry.point(in: .triple(20))!
        func gaussian() -> Double {
            let u = Double.random(in: 0.0001...1), v = Double.random(in: 0...1)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        let point = BoardPoint(x: aim.x + gaussian() * 0.13, y: aim.y + gaussian() * 0.13)
        return DetectedDart(segment: BoardGeometry.segment(at: point),
                            boardPosition: point,
                            confidence: Double.random(in: 0.55...0.98))
    }

    /// A detected dart in the middle of a bed.
    nonisolated static func dart(_ segment: Segment, confidence: Double = 0.93, offset: Double = 0.2) -> DetectedDart {
        DetectedDart(segment: segment,
                     boardPosition: BoardGeometry.point(in: segment, angleOffset: offset, radialOffset: -offset),
                     confidence: confidence)
    }
}

/// What the "camera" sees in demo mode: a board on a wall with the current darts.
struct DemoCameraScene: View {
    @ObservedObject var source: DemoDetectionSource

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(hex: 0x3A3F3C), Color(hex: 0x1E2220)], startPoint: .top, endPoint: .bottom)
                if source.status != .searching {
                    BoardView(markers: source.boardDarts.compactMap { dart in
                        dart.boardPosition.map { BoardView.Marker(id: UUID(), position: $0) }
                    })
                    .frame(width: min(geo.size.width, geo.size.height) * 0.82)
                    .rotation3DEffect(.degrees(source.status == .aligning ? 22 : 9), axis: (x: 0.3, y: 1, z: 0), perspective: 0.6)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
                    .offset(x: source.status == .aligning ? geo.size.width * 0.12 : 0)
                } else {
                    // Board out of frame: only the wall is visible.
                    Rectangle()
                        .fill(Color.white.opacity(0.04))
                        .frame(width: geo.size.width * 0.3, height: geo.size.height * 0.5)
                        .offset(x: -geo.size.width * 0.3)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.snappy, value: source.status)
        }
        .ignoresSafeArea()
    }
}

/// Scripted app states for simulator screenshots and demos, picked with `-demoScenario <name>`.
struct DemoScenario {
    enum Screen { case home, game, camera }

    let name: String
    var screen: Screen = .game
    var rules = X01Rules(startScore: 501, doubleOut: true)
    var players = ["Alex", "Sam"]
    /// Earlier visits in throwing order (players alternate).
    var history: [[Segment]] = []
    var script = DemoDetectionSource.Script()
    var openPickerSlot: Int?
    var expandCamera = false
    /// Uses the camera source (shows the no-camera state in the simulator).
    var usesCamera = false

    static var current: DemoScenario? {
        guard let name = UserDefaults.standard.string(forKey: "demoScenario") else { return nil }
        return named(name)
    }

    var match: X01Match {
        var match = X01Match(rules: rules, players: players)
        for visit in history {
            for segment in visit { match.add(DemoDetectionSource.dart(segment, confidence: 0.9).asDart) }
            match.endVisit()
        }
        return match
    }

    // Visits used below. T = treble, D = double.
    private static let t20t20s20: [Segment] = [.triple(20), .triple(20), .single(20)]   // 140
    private static let t20s20s20: [Segment] = [.triple(20), .single(20), .single(20)]   // 100

    static func named(_ name: String) -> DemoScenario? {
        switch name {
        case "home", "play":
            return DemoScenario(name: name, screen: .home)
        case "live", "picker", "framing":
            // Alex on 170 throws T20 T20 → 50 left, bull to finish.
            var scenario = DemoScenario(name: name)
            scenario.history = [
                t20t20s20, [.triple(20), .single(5), .single(20)],
                t20s20s20, t20s20s20,
                [.triple(19), .single(20), .single(14)], [.triple(20), .single(19), .single(5)],
            ]
            scenario.script.darts = [DemoDetectionSource.dart(.triple(20), confidence: 0.94),
                                     DemoDetectionSource.dart(.triple(20), confidence: 0.81, offset: -0.5)]
            if name == "picker" { scenario.openPickerSlot = 1 }
            if name == "framing" { scenario.expandCamera = true }
            return scenario
        case "route":
            // Alex on 141, nothing thrown yet: T20 T19 D12.
            var scenario = DemoScenario(name: name)
            scenario.history = [
                t20t20s20, t20s20s20,
                t20s20s20, [.triple(19), .single(7), .single(1)],
                [.triple(20), .triple(20), .miss], t20s20s20,
            ]
            return scenario
        case "bust":
            // Sam on 32 throws 20 then T5: below zero.
            var scenario = DemoScenario(name: name)
            scenario.history = [
                t20s20s20, t20t20s20,
                [.triple(19), .single(20), .single(8)], [.triple(20), .triple(20), .triple(20)],
                [.triple(20), .miss, .miss], [.triple(20), .triple(19), .double(16)],
                [.single(20), .single(20), .single(5)],
            ]
            scenario.script.darts = [DemoDetectionSource.dart(.single(20), confidence: 0.95),
                                     DemoDetectionSource.dart(.triple(5), confidence: 0.58)]
            return scenario
        case "checkout", "summary":
            // Alex on 81 finishes T19 D12.
            var scenario = DemoScenario(name: name)
            scenario.history = [
                t20t20s20, t20s20s20,
                t20t20s20, t20t20s20,
                t20t20s20, [.triple(20), .triple(20), .triple(15)],
            ]
            let finish = [DemoDetectionSource.dart(.triple(19), confidence: 0.92),
                          DemoDetectionSource.dart(.double(12), confidence: 0.86)]
            if name == "summary" {
                scenario.history.append([.triple(19), .double(12)])
            } else {
                scenario.script.darts = finish
            }
            return scenario
        case "searching", "aligning", "ready":
            var scenario = DemoScenario(name: name, screen: .camera)
            scenario.script.status = name == "searching" ? .searching : (name == "aligning" ? .aligning : .ready)
            return scenario
        case "nocamera":
            var scenario = DemoScenario(name: name)
            scenario.history = [t20s20s20]
            scenario.usesCamera = true
            return scenario
        case "camera":
            var scenario = DemoScenario(name: name, screen: .camera)
            scenario.usesCamera = true
            return scenario
        default:
            return nil
        }
    }
}
#endif
