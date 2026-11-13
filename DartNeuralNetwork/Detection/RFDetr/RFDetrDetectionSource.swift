@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Delivers frames to a `DetectionEngine` (camera, or still images in DEBUG builds).
@MainActor
protocol FrameFeed: AnyObject {
    /// Starts calling `engine.process` on `engine.queue` and shows the live view in `preview`.
    /// Calls `failed` when no frames can come (no camera, access denied).
    func start(engine: DetectionEngine, preview: PreviewHostView, failed: @escaping @MainActor () -> Void)
    func stop()
}

/// The debug view's data: the latest `DetectorSnapshot`, published on the main actor.
@MainActor
final class DetectorDebugModel: ObservableObject {
    @Published private(set) var snapshot: DetectorSnapshot?
    /// Snapshots are only produced while someone shows them.
    var isShown = false {
        didSet {
            guard isShown != oldValue else { return }
            onShownChange?(isShown)
            if !isShown { snapshot = nil }
        }
    }
    fileprivate var onShownChange: ((Bool) -> Void)?

    func publish(_ snapshot: DetectorSnapshot) {
        if isShown { self.snapshot = snapshot }
    }
}

/// Dart detection with the RF-DETR model (v6rf12h) and multi-frame tracking.
///
/// The model runs on `DetectionEngine.queue`; `MultiFrameTracker` turns its per-frame output into
/// board status, darts and board clears. Events reach `onEvent` on the main actor in the order
/// the engine produced them.
///
/// Commands from the game take effect at once although the engine runs them later: each
/// `endVisit()`, `resumeVisit()` and `reset()` starts a new generation, the engine stamps its
/// outputs with the generation it had when it made them, and darts and clears of an older
/// generation are dropped here, also in the middle of a batch.
@MainActor
final class RFDetrDetectionSource: DartDetectionSource {
    private(set) var status: BoardStatus = .searching {
        didSet { if status != oldValue { onEvent?(.status(status)) } }
    }
    var onEvent: ((DetectionEvent) -> Void)?
    let debugModel: DetectorDebugModel? = DetectorDebugModel()

    private let feed: FrameFeed
    private let engine: DetectionEngine
    private let previewHost = PreviewHostView()
    private var running = false
    /// Counts the game's commands; see the type's comment.
    private var generation = 0

    /// `loadModel` is replaceable for tests and the DEBUG failure preview.
    init(feed: FrameFeed, ignoresDartsAtStart: Bool = true,
         loadModel: @escaping () throws -> RFDetrModel = { try RFDetrModel.loadBundled() }) {
        self.feed = feed
        engine = DetectionEngine(ignoresDartsAtStart: ignoresDartsAtStart, loadModel: loadModel)
        engine.output = { [weak self] output in
            // Main queue blocks run in submission order, so events keep their order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(output) }
            }
        }
        debugModel?.onShownChange = { [engine] shown in engine.setDebugEnabled(shown) }
        engine.prepare()
    }

    /// The camera-based source used in games.
    static func camera() -> RFDetrDetectionSource { RFDetrDetectionSource(feed: CameraFeed()) }

    func start() {
        guard !running else { return }
        running = true
        if status == .cameraUnavailable { status = .searching }
        engine.retryModelIfFailed()
        feed.start(engine: engine, preview: previewHost) { [weak self] in
            self?.running = false
            self?.status = .cameraUnavailable
        }
    }

    func stop() {
        guard running else { return }
        running = false
        feed.stop()
        engine.cameraStopped()
    }

    func endVisit() { generation += 1; engine.endVisit(generation: generation) }
    func resumeVisit() { generation += 1; engine.resumeVisit(generation: generation) }
    func reset() { generation += 1; engine.reset(generation: generation) }
    func makePreviewView() -> UIView { previewHost }

    func saveRecording(into folder: URL) async -> DetectorRecorder.Summary? {
        await withCheckedContinuation { continuation in
            engine.saveRecording(to: folder) { continuation.resume(returning: $0) }
        }
    }

    private func apply(_ output: DetectionEngine.Output) {
        for event in output.events {
            if case .status(let next) = event {
                if status != .cameraUnavailable { status = next }
            } else if output.generation == generation {
                // Checked per event: delivering one (a bust) may end the visit mid-batch.
                onEvent?(event)
            }
        }
        if let snapshot = output.snapshot { debugModel?.publish(snapshot) }
    }
}

// MARK: - Camera

/// Back camera at 4K, frames delivered on the engine's queue; late frames are discarded.
@MainActor
final class CameraFeed: NSObject, FrameFeed {
    private var session: AVCaptureSession?
    private var delegate: CameraFrameDelegate?
    private let sessionQueue = DispatchQueue(label: "jb.darts.camera-session")

    func start(engine: DetectionEngine, preview: PreviewHostView, failed: @escaping @MainActor () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run(engine: engine, preview: preview, failed: failed)
        case .notDetermined:
            Task { @MainActor in
                if await AVCaptureDevice.requestAccess(for: .video) {
                    self.run(engine: engine, preview: preview, failed: failed)
                } else {
                    failed()
                }
            }
        default:
            failed()
        }
    }

    func stop() {
        guard let session else { return }
        sessionQueue.async { session.stopRunning() }
    }

    private func run(engine: DetectionEngine, preview: PreviewHostView, failed: @escaping @MainActor () -> Void) {
        if let session {
            sessionQueue.async { session.startRunning() }
            return
        }
        guard let session = Self.makeSession(engine: engine, delegate: &delegate) else { failed(); return }
        self.session = session
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.name = "dartPreviewLayer"
        layer.videoGravity = .resizeAspectFill
        if layer.connection?.isVideoRotationAngleSupported(90) == true { layer.connection?.videoRotationAngle = 90 }
        layer.frame = preview.bounds
        preview.layer.insertSublayer(layer, at: 0)
        sessionQueue.async { session.startRunning() }
    }

    private static func makeSession(engine: DetectionEngine, delegate: inout CameraFrameDelegate?) -> AVCaptureSession? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(DetectorTuning.cameraPreset)
            ? DetectorTuning.cameraPreset : DetectorTuning.fallbackCameraPreset
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        let frameDelegate = CameraFrameDelegate(engine: engine)
        output.setSampleBufferDelegate(frameDelegate, queue: engine.queue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        delegate = frameDelegate

        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        }
        return session
    }
}

/// Receives camera frames on the engine's queue. The buffers stay in sensor orientation; the
/// preprocessing turns them upright (`FrameImage.Orientation.right`) while sampling.
private final class CameraFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let engine: DetectionEngine

    init(engine: DetectionEngine) { self.engine = engine }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        engine.process(FrameImage(pixelBuffer: buffer, orientation: .right), time: time)
    }
}
