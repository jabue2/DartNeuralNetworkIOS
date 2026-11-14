import CoreGraphics
import Foundation
import QuartzCore
import simd

/// What the detector saw in one frame, for the debug view. Pixels of the upright frame.
struct DetectorSnapshot {
    struct RawDart { var pixel: SIMD2<Double>; var confidence: Double }
    struct TrackMark { var pixel: SIMD2<Double>; var hits: Int; var evidence: Double; var isBackground: Bool }
    struct DartMark { var pixel: SIMD2<Double>; var label: String }

    var imageSize: CGSize
    /// The region the model looked at in this frame.
    var crop: CGRect
    /// Board millimetres → image pixels, while locked.
    var boardToImage: Homography?
    var calibration: [MultiFrameTracker.CalibrationReport]
    /// Where the 12 calibration points should be under the lock.
    var expectedCalibration: [SIMD2<Double>]
    var darts: [RawDart]
    var tracks: [TrackMark]
    var visitDarts: [DartMark]
    var oldDarts: [DartMark]
    var frameUse: MultiFrameTracker.FrameUse
    var phase: MultiFrameTracker.Phase
    var status: BoardStatus
    var lockRMSErrorMM: Double?
    var inferenceMilliseconds: Double
    var framesPerSecond: Double
}

/// Owns the model and the multi-frame tracker. All of its state lives on `queue`: frames are
/// processed there synchronously (frames arriving meanwhile are dropped by the feed, never
/// queued), and commands from the game are dispatched onto it, so frames and commands are
/// handled in one order.
final class DetectionEngine: @unchecked Sendable {
    struct Output {
        /// Events of one frame, in order.
        var events: [DetectionEvent]
        var snapshot: DetectorSnapshot?
        /// The command generation the events were produced under (see `endVisit(generation:)`).
        var generation: Int
    }

    let queue = DispatchQueue(label: "jb.darts.detection", qos: .userInitiated)
    /// Called on `queue`. Set before the first frame.
    var output: ((Output) -> Void)?

    // Confined to `queue`.
    private let loadModel: () throws -> RFDetrModel
    private var model: RFDetrModel?
    /// Frame time of the last failed load; nil while the model is loaded or not yet tried.
    private var modelFailedAt: CFTimeInterval?
    /// Generation of the last command from the game; stamped on every output.
    private var generation = 0
    private var tracker: MultiFrameTracker
    private var lastFrameTime: CFTimeInterval = 0
    private var framesPerSecond = 0.0
    private var debugEnabled = false
    /// The last seconds of frames, detections and commands, for reporting a mistake.
    let recorder: DetectorRecorder

    /// `loadModel` is replaceable for tests.
    /// Seconds (frame time) between tracker checkpoints in the recording; see `DetectorRecorder`.
    private let checkpointSeconds: Double
    private var lastCheckpointTime: CFTimeInterval?

    init(ignoresDartsAtStart: Bool, recorder: DetectorRecorder = DetectorRecorder(), checkpointSeconds: Double = 30,
         loadModel: @escaping () throws -> RFDetrModel = { try RFDetrModel.loadBundled() }) {
        tracker = MultiFrameTracker(ignoresDartsAtStart: ignoresDartsAtStart)
        self.recorder = recorder
        self.checkpointSeconds = checkpointSeconds
        self.loadModel = loadModel
        recorder.record(checkpoint: tracker)   // the start: a replay of a log not yet trimmed starts here
    }

    /// Loads the model in the background so the first frame does not wait for it.
    func prepare() {
        queue.async { _ = self.loadedModel(time: nil) }
    }

    /// Tries again to load a model that failed to load (called when the source starts again).
    func retryModelIfFailed() {
        queue.async {
            guard self.modelFailedAt != nil else { return }
            _ = self.loadedModel(time: nil, now: true)
        }
    }

    // Commands from the game. Each carries the source's new generation: outputs produced before
    // the command ran carry an older one, so the source can drop their darts and clears.
    func endVisit(generation: Int) {
        queue.async { self.generation = generation; self.tracker.endVisit(); self.recorder.record(command: "endVisit") }
    }
    func resumeVisit(generation: Int) {
        queue.async { self.generation = generation; self.tracker.resumeVisit(); self.recorder.record(command: "resumeVisit") }
    }
    func reset(generation: Int) {
        queue.async { self.generation = generation; self.tracker.reset(); self.recorder.record(command: "reset") }
    }
    func cameraStopped() { queue.async { self.tracker.cameraRestarted(); self.recorder.record(command: "cameraStopped") } }

    /// Saves the recording of the last seconds into `folder`, including every frame processed
    /// before this call. `completion` runs on the recorder's queue.
    func saveRecording(to folder: URL, completion: @escaping (DetectorRecorder.Summary?) -> Void) {
        queue.async { self.recorder.save(to: folder, completion: completion) }
    }
    func setDebugEnabled(_ enabled: Bool) { queue.async { self.debugEnabled = enabled } }

    /// Processes a frame. Must be called on `queue`; skips frames beyond `maxFramesPerSecond`.
    func process(_ frame: FrameImage, time: CFTimeInterval) {
        dispatchPrecondition(condition: .onQueue(queue))
        let interval = time - lastFrameTime
        guard interval >= 0.95 / DetectorTuning.maxFramesPerSecond || interval < 0 else { return }
        guard let model = loadedModel(time: time) else { return }
        if lastFrameTime > 0, interval < 2 {
            framesPerSecond = framesPerSecond == 0 ? 1 / interval : framesPerSecond * 0.85 + 0.15 / interval
        }
        lastFrameTime = time

        let crop = tracker.crop
        let started = CACurrentMediaTime()
        guard let detections = try? model.detect(in: frame, crop: crop) else { return }
        let milliseconds = (CACurrentMediaTime() - started) * 1000
        let observation = FrameObservation(imageSize: frame.size, crop: crop, detections: detections)
        if let last = lastCheckpointTime, time >= last, time - last < checkpointSeconds {
            // Not yet due.
        } else {
            lastCheckpointTime = time
            recorder.record(checkpoint: tracker, time: time)
        }
        let events = tracker.process(observation)
        record(observation, events: events, milliseconds: milliseconds, time: time, image: frame)
        let snapshot = debugEnabled ? makeSnapshot(observation, milliseconds: milliseconds) : nil
        if !events.isEmpty || snapshot != nil { output?(Output(events: events, snapshot: snapshot, generation: generation)) }
    }

    /// The model, loading it if needed. A failed load is reported as `.detectorUnavailable` and
    /// tried again `modelRetrySeconds` (frame time) later, or when the source starts again.
    /// After a failure, a successful load reports the tracker's status again.
    private func loadedModel(time: CFTimeInterval?, now: Bool = false) -> RFDetrModel? {
        if let model { return model }
        if !now, let failedAt = modelFailedAt {
            // Frame times may be on another clock than the failure (nil when it failed outside a
            // frame): start the wait at the first frame then.
            guard let time else { return nil }
            if failedAt < 0 || time < failedAt { modelFailedAt = time; return nil }
            guard time - failedAt >= DetectorTuning.modelRetrySeconds else { return nil }
        }
        let wasFailing = modelFailedAt != nil
        do {
            model = try loadModel()
            modelFailedAt = nil
            if wasFailing { output?(Output(events: [.status(tracker.status)], snapshot: nil, generation: generation)) }
        } catch {
            print("RF-DETR model failed to load: \(error)")
            modelFailedAt = time ?? -1
            output?(Output(events: [.status(.detectorUnavailable)], snapshot: nil, generation: generation))
        }
        return model
    }

    private func record(_ frame: FrameObservation, events: [DetectionEvent], milliseconds: Double,
                        time: CFTimeInterval, image: FrameImage) {
        func darts(_ list: [MultiFrameTracker.ConfirmedDart]) -> [DetectorRecorder.TrackedDart] {
            list.map { .init(label: $0.segment.label, x: $0.boardMM.x, y: $0.boardMM.y) }
        }
        let h = tracker.homography?.rows
        let region = RFDetrModel.inputRegion(crop: frame.crop, frameSize: frame.imageSize)
        let entry = DetectorRecorder.Frame(
            width: frame.imageSize.width, height: frame.imageSize.height,
            crop: [region.minX, region.minY, region.width, region.height],
            detections: frame.detections.map { .init(c: $0.classIndex, x: $0.point.x, y: $0.point.y, p: $0.confidence) },
            events: events.map(DetectorRecorder.describe),
            phase: DetectorRecorder.name(of: tracker.phase),
            use: DetectorRecorder.name(of: tracker.lastFrameUse),
            status: ScoreboardSnapshot.name(of: tracker.status),
            homography: h,
            visitDarts: darts(tracker.resumedDarts + tracker.visitDarts),
            oldDarts: darts(tracker.oldDarts),
            inferenceMilliseconds: milliseconds,
            image: false)
        recorder.record(frame: entry, time: time, image: (image, region))
    }

    private func makeSnapshot(_ frame: FrameObservation, milliseconds: Double) -> DetectorSnapshot {
        let toImage = tracker.homography?.inverse
        func pixel(_ mm: SIMD2<Double>) -> SIMD2<Double>? { toImage?.apply(mm) }
        return DetectorSnapshot(
            imageSize: frame.imageSize,
            crop: frame.crop,
            boardToImage: toImage,
            calibration: tracker.lastCalibration,
            expectedCalibration: BoardCalibration.targetsMM.compactMap(pixel),
            darts: frame.darts(minConfidence: DetectorTuning.trackFloor).map { .init(pixel: $0.point, confidence: $0.confidence) },
            tracks: tracker.tracks.compactMap { t in
                pixel(t.tipMM).map { .init(pixel: $0, hits: t.observations.count, evidence: tracker.evidence(of: t), isBackground: t.isHeldBack) }
            },
            visitDarts: (tracker.resumedDarts + tracker.visitDarts).compactMap { d in pixel(d.boardMM).map { .init(pixel: $0, label: d.segment.label) } },
            oldDarts: tracker.oldDarts.compactMap { d in pixel(d.boardMM).map { .init(pixel: $0, label: d.segment.label) } },
            frameUse: tracker.lastFrameUse,
            phase: tracker.phase,
            status: tracker.status,
            lockRMSErrorMM: tracker.lockRMSErrorMM,
            inferenceMilliseconds: milliseconds,
            framesPerSecond: framesPerSecond)
    }
}
