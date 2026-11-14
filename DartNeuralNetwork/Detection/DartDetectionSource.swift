import UIKit

// The seam between dart detection and the game.
//
// Game screens only see `DartDetectionSource`, `DetectionEvent`, `DetectedDart`
// and `BoardStatus`. A detector (`RFDetrDetectionSource`: RF-DETR model plus
// multi-frame tracking) turns camera frames into these values. Scoring rules live
// in `X01Match`, not in the detector.

/// How well the camera currently sees the board.
enum BoardStatus: Equatable, Codable {
    /// No camera, or camera access denied.
    case cameraUnavailable
    /// The camera runs, but the dart detector could not start (its model failed to load), so
    /// nothing is scored automatically. The source retries on its own and on the next `start()`.
    case detectorUnavailable
    /// Camera running, no board in view.
    case searching
    /// Board in view but not enough calibration points for scoring
    /// (also while a player stands in front of it).
    case aligning
    /// Board found and calibrated; darts are scored.
    case ready

    var isScoring: Bool { self == .ready }
}

/// A dart the detector has confirmed on the board.
struct DetectedDart: Equatable {
    var segment: Segment
    /// Tip position on the board face (see `BoardPoint`), when known.
    var boardPosition: BoardPoint?
    /// 0...1
    var confidence: Double

    var asDart: Dart { Dart(segment: segment, boardPosition: boardPosition, confidence: confidence) }
}

enum DetectionEvent: Equatable {
    case status(BoardStatus)
    /// A new dart landed. Each physical dart is reported once per visit.
    case dartDetected(DetectedDart)
    /// The detector ended the current visit on its own: the visit's darts (fewer than three,
    /// the others missed the board) were pulled. A `.boardCleared` follows once the darts are
    /// pulled (the RF-DETR source sends both together), and the game counts the empty slots as misses.
    case visitEnded
    /// The darts of the last visit were pulled and the board is empty again.
    case boardCleared
}

@MainActor
protocol DartDetectionSource: AnyObject {
    var status: BoardStatus { get }
    /// Delivered on the main actor.
    var onEvent: ((DetectionEvent) -> Void)? { get set }

    func start()
    func stop()
    /// The visit is over (three darts, bust, finish or manual next). Stop reporting new
    /// darts until the board is cleared, then send `.boardCleared`. Takes effect at once: no
    /// `.dartDetected` or `.boardCleared` found before the call is delivered after it, even
    /// from a batch of events being delivered while it is called. The same holds for
    /// `resumeVisit()` and `reset()`.
    func endVisit()
    /// Undo or a correction reopened the visit that `endVisit()` closed: report new darts
    /// again, without reporting the darts of this visit that are already on the board.
    func resumeVisit()
    /// New game. Forget the scores, but if darts may still be on the board, report
    /// nothing until it is visibly clear.
    func reset()
    /// The live view to show for framing. Called once per source; the view may be
    /// moved between containers.
    func makePreviewView() -> UIView
    /// What the detector sees, for the debug view on the framing screen. Nil when the source
    /// has nothing to show (demo, tests).
    var debugModel: DetectorDebugModel? { get }
    /// Saves what the detector saw in the last seconds into `folder` (see `DetectorRecorder`).
    /// Nil when the source records nothing (demo, tests) or saving failed.
    func saveRecording(into folder: URL) async -> DetectorRecorder.Summary?
}

extension DartDetectionSource {
    var debugModel: DetectorDebugModel? { nil }
    func saveRecording(into folder: URL) async -> DetectorRecorder.Summary? { nil }
}

enum DetectionSourceFactory {
    /// The detector used by game screens. In DEBUG builds, `-replayFolder <path>` feeds still
    /// images through the real model (see `ReplayFrameFeed`; add `-simulateModelLoadFailure YES`
    /// to see the detector-failure state); otherwise the simulator, or the
    /// `-demoScenario` launch argument, use the scripted demo source instead of the camera.
    @MainActor
    static func make() -> DartDetectionSource {
        #if DEBUG
        if let replay = ReplayFrameFeed.fromLaunchArguments() {
            // `-simulateModelLoadFailure YES` shows the detector-failure state with the replay.
            if UserDefaults.standard.bool(forKey: "simulateModelLoadFailure") {
                return RFDetrDetectionSource(feed: replay, ignoresDartsAtStart: false) {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            return RFDetrDetectionSource(feed: replay, ignoresDartsAtStart: false)
        }
        if let demo = DemoDetectionSource.fromLaunchArguments() { return demo }
        #endif
        return RFDetrDetectionSource.camera()
    }
}

/// Hosts a camera preview layer or a replay/demo view and keeps it sized to its bounds.
final class PreviewHostView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Camera view"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers?.filter { $0.name == "dartPreviewLayer" }.forEach { $0.frame = bounds }
        CATransaction.commit()
        subviews.forEach { $0.frame = bounds }
    }
}
