import AVFoundation
import Foundation

/// Every tuning constant of the RF-DETR detector in one place.
///
/// Frame counts are counted in processed frames (about `maxFramesPerSecond` per second), not
/// camera frames. The reference numbers come from the offline evaluation of v6rf12 (576 px); the bundled model is now v6rf12h (800 px), whose confidences were not re-tuned on video
/// (`~/DartSynthetic/public_check`): calibration is essentially solved, about 1% of darts are
/// never seen, 8-14% are seen only below 0.25 confidence, and 5-8% land in the neighbouring
/// segment, mostly tips within 2 mm of a wire.
enum DetectorTuning {
    // MARK: Model and decoding

    /// Side of the square model input in pixels: v6rf12h, RF-DETR Medium trained at 800 (v6rf12 was 576).
    static let modelInputSide = 800
    /// Lowest confidence decoded at all. The tracker and the debug view filter further.
    static let decodeFloor = 0.02
    /// Same-class detections closer than this (fraction of the model input, i.e. of the crop)
    /// are one object; the most confident one is kept. RF-DETR has no NMS. Offline `MIN_D=.02`.
    static let duplicateMergeDistance = 0.02

    // MARK: Calibration and board lock

    /// A calibration point counts at this confidence or more (offline reference).
    static let calibrationConfidence = 0.25
    /// RANSAC inlier threshold for the image-to-board homography (offline reference).
    static let ransacThresholdMM = 6.0
    /// Consecutive calibrated frames that agree with each other before the board locks.
    /// Four frames (about a third of a second) is enough to reject a moving phone.
    static let lockFramesNeeded = 4
    /// While forming a lock, a frame agrees when its points fit the median homography this well (RMS).
    static let lockAgreementMM = 4.0
    /// Recent confident observations kept per calibration point; the lock uses their median.
    static let calibrationHistory = 15
    /// Once locked, a calibration point agrees with the lock when it lands this close to its
    /// target. Same as the RANSAC threshold.
    static let pointAgreementMM = 6.0
    /// Consecutive frames whose calibration points disagree with the lock before the detector
    /// decides the camera moved and locks again. Darts in board millimetres survive a re-lock.
    static let movedFramesNeeded = 3
    /// Frames without a usable view before the lock is dropped and the model looks at the whole
    /// frame again (about two and a half seconds: longer than a player pulling darts).
    static let lostFramesBeforeUnlock = 30
    /// A frame is a "clear view" when at most this many fewer calibration points agree than were
    /// visible at lock time. Only clear views count a dart as missing or the board as empty, so a
    /// player standing in front of part of the board does not look like an empty board.
    static let clearViewMissingPoints = 2
    /// Frames without a usable view before the status turns from ready to aligning.
    static let occludedFramesBeforeAligning = 4
    /// Frames with fewer than two calibration points before the status turns to searching.
    static let emptyFramesBeforeSearching = 6
    /// A new status must be seen this many frames in a row before it is reported (no flicker).
    static let statusDebounceFrames = 2

    // MARK: Crop

    /// Once locked, the model looks at the board's bounding box (board edge 225.5 mm, from the
    /// homography) plus this margin per side, stretched to the model input square. This is how the offline
    /// two-pass evaluation cropped (`crop_box`, margin .02), so it is the measured setup.
    static let boardEdgeMM = 225.5
    static let cropMargin = 0.02
    /// Recompute the crop when the locked board moved by more than this fraction of the crop.
    static let cropUpdateFraction = 0.02
    /// Crops smaller than this (pixels) are not worth it; use the whole frame.
    static let minimumCropSide = 96.0

    // MARK: Dart tracks (board millimetres)

    /// Dart detections below this confidence are ignored by the tracker. Offline, darts below
    /// 0.25 are mostly between 0.02 and 0.25; 0.08 keeps most of them while flicker below it is
    /// mostly noise. Persistence (below) does the rest.
    static let trackFloor = 0.08
    /// A detection joins an existing track within this distance of the track's tip.
    static let associationRadiusMM = 12.0
    /// A track becomes a dart when, within the last `evidenceWindow` usable frames, it was seen
    /// at least `confirmMinHits` times and its confidences add up to `confirmEvidence`.
    /// One frame at 0.25 alone (the single-frame rule) is not enough; three frames at 0.34, or ten
    /// at 0.1, are.
    static let evidenceWindow = 15
    static let confirmMinHits = 3
    static let confirmEvidence = 1.0
    /// ...and it was seen in at least this share of the usable frames since it appeared, so a
    /// flickering low-confidence false detection does not confirm.
    static let confirmMinHitRatio = 0.6
    /// A tip this close to a wire waits for `wireExtraHits` observations before it is reported,
    /// because a median of more frames is less likely to land on the wrong side.
    static let wireMarginMM = 1.5
    static let wireExtraHits = 6
    /// Observations kept per track for the median tip.
    static let tipObservationsKept = 30
    /// An unconfirmed track is dropped after this many clear views in a row without it.
    static let maxMissStreak = 5
    /// Tracks that predate a board clear or a reset are background (darts left in the board or
    /// fixed false detections): they never confirm and are forgotten after this many clear
    /// views without them.
    static let backgroundForgetFrames = 10
    /// Detections within this distance of a dart already reported (this visit or a closed one
    /// still in the board) belong to that dart: never reported again. About the duplicate-merge
    /// distance on a board-sized crop (2% of ~470 mm).
    static let confirmedDartRadiusMM = 10.0
    /// Detections farther than this from the board centre are ignored (board edge is 225.5 mm).
    static let maxDartRadiusMM = 235.0
    static let maxDartsPerVisit = 3
    /// Tracks that appear in the first usable frames after the detector starts are background:
    /// darts left in the board from before are not scored for the first player. (Off for replay.)
    static let startupBaselineFrames = 3

    // MARK: Removal

    /// A dart of a closed visit counts as still there when any dart detection at this confidence
    /// or more lies within `confirmedDartRadiusMM` of it in the current frame.
    static let presenceFloor = 0.05
    /// Clear views in a row with none of the closed visit's darts before `.boardCleared`.
    static let removalFramesNeeded = 8
    /// After a clear, new tracks near a removed dart stay background this long, in case a hand
    /// hid a dart while the board looked empty.
    static let removedMemoryFrames = 30
    /// ...after which such a track is judged like any other, so a new dart in the same bed scores.
    /// (A dart a hand hid through the whole clear is then reported once it shows again; at
    /// about 12 frames per second the player has walked back to the oche long before.)

    // MARK: Camera and pacing

    /// 4K frames: the board crop then keeps most of the model's input pixels even from the oche.
    static let cameraPreset: AVCaptureSession.Preset = .hd4K3840x2160
    static let fallbackCameraPreset: AVCaptureSession.Preset = .hd1920x1080
    /// Upper bound on processed frames per second (heat and battery). Frames arriving while the
    /// model runs are dropped, never queued.
    static let maxFramesPerSecond = 12.0
    /// After the model failed to load, it is tried again after this many seconds of frames (and
    /// whenever the source starts again). The board status shows `.detectorUnavailable` meanwhile.
    static let modelRetrySeconds = 10.0
}
