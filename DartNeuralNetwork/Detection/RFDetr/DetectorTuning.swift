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
    /// are one object; the most confident one is kept. RF-DETR has no NMS. Offline `MIN_D=.02`,
    /// and still the rule for calibration points and for single photos.
    static let duplicateMergeDistance = 0.02
    /// Live darts merge more narrowly: always within `sameTipMergeDistance` (about 4 mm on a
    /// board crop), but between that and `duplicateMergeDistance` only when the weaker detection
    /// is below `secondTipConfidence`. Stacked darts sit 7-9.5 mm apart and the model sees the
    /// second one at 0.6-0.85, while the duplicates it makes of one dart stay mostly below 0.5
    /// (all 37 phone reports, 2026-11-15). The 0.02 merge was discarding three stacked darts.
    static let sameTipMergeDistance = 0.008
    static let secondTipConfidence = 0.5

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
    /// Calibration points that must fit one board in a single frame before points that disagree
    /// with the lock refine it. Eight leave a homography (eight unknowns) well over-determined,
    /// so a few points thrown off by a hand or a shadow cannot pull the lock.
    static let relearnMinPoints = 8
    /// ...and every one of them within this distance of its target under that frame's own fit.
    /// Sharp full-board frames on the phone fit within 0.8 mm at their worst point (median; 1 mm
    /// for 90%), while a fit bent to take in a few misplaced points misses some by several mm.
    static let relearnFitMM = 2.0
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
    /// One frame at 0.25 alone (the single-frame rule) is not enough; three frames at 0.34 are,
    /// and so are ten faint frames once one of them reached `confirmMinPeakConfidence`.
    static let evidenceWindow = 15
    static let confirmMinHits = 3
    static let confirmEvidence = 1.0
    /// ...and it was seen at this confidence or more at least once. On the phone (21 mistake
    /// reports, 2026-11-13), at least 9 of the 11 darts confirmed while never reaching 0.3 were wrong
    /// (barrel points, phantoms), while real darts on that board mostly peaked at 0.6-0.87. A dart
    /// only ever seen fainter is entered by hand.
    static let confirmMinPeakConfidence = 0.3
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
    /// Inside this distance a detection always belongs to the reported dart. Between it and
    /// `confirmedDartRadiusMM` a strong detection may be a second dart stacked next to the first
    /// (phone reports: 7-9.5 mm apart); it is reported only as a `stackedDart...` below.
    static let sameDartRadiusMM = 4.0
    /// A dart next to a reported one (within `stackedZoneMM`) counts only when its track
    /// started after that dart was reported, and its last `stackedDartFrames` usable frames in a
    /// row were all at `stackedDartConfidence` or more, within `stackedDartSpreadMM` of their
    /// median, with the reported dart's own tip seen within `stackedNeighbourMM` in at least half
    /// of them, and it is not where a point appeared together with that dart (its barrel points,
    /// see `sameLandingFrames`). The one duplicate of a dart in the 37 phone reports (22-51-58)
    /// appeared with its dart, wandered 2.5-11.6 mm away and flickered between 0.06 and 0.55;
    /// stacked darts appeared seconds later and stayed at 0.6-0.85. Tip jitter of a still dart
    /// is 0.3 mm median, 0.8 p90. Replaying the 37 reports with the model re-run on their frames
    /// (2026-11-15), this and the live merge found 6 stacked darts the phone had lost (and one
    /// 3 s sooner) and changed nothing else: no double, no new false dart.
    /// The neighbour's tip counts as seen within `sameDartRadiusMM`: a dart landing 8 mm away
    /// can nudge the first one or cover part of its tip, and on the phone (2026-11-16, 16-05-00)
    /// the first dart's detection then sat 3 mm off for seconds, which held the second dart back 5 s.
    static let stackedDartFrames = 6
    static let stackedDartConfidence = 0.5
    static let stackedDartSpreadMM = 1.5
    static let stackedNeighbourMM = sameDartRadiusMM
    /// A track whose tip lies this close to a dart of the open visit (wider than
    /// `confirmedDartRadiusMM`) needs that stacked-dart evidence, whatever its history: the one
    /// duplicate in the phone reports wandered up to 11.6 mm from its dart, and a duplicate's track
    /// can expire and start again just outside the radius (review, 2026-11-15).
    static let stackedZoneMM = 13.0
    /// Beyond `confirmedDartRadiusMM` a stacked dart needs each of its frames at this or more
    /// (and its neighbour's tip need not be seen): a steady weaker dart scores, a flickering
    /// duplicate (down to 0.3) does not. Known limit (review, 2026-11-15): a duplicate held steady
    /// at 0.4 or more just past 10 mm scores, as it did before this zone existed; on the phone the
    /// one duplicate seen flickered and never held steady.
    static let stackedOuterConfidence = 0.4
    /// Detections farther than this from the board centre are ignored: the scoring area ends at
    /// 170 mm, and the margin only lets a track near the double ring keep its outlying observations.
    /// Tracks whose tip lies outside 170 mm are never reported either. A miss scores nothing, and
    /// from a steep angle the model also fires along a dart's barrel and flight, which reach past
    /// the double ring; reporting those as misses ended visits early (phone test, 2026-11-11).
    /// Misses are filled in when a short visit's darts are pulled (`pullFramesNeeded`).
    static let maxDartRadiusMM = 180.0
    /// Detections on opposite sides of the outer double wire join one track only when both lie
    /// within this distance of the wire (tip noise); farther apart they are different objects.
    static let ringJoinMarginMM = 1.5
    static let maxDartsPerVisit = 3
    /// One landing, one dart. When a dart lands, the model often also fires weakly along its barrel
    /// (13-36 mm from the tip in 9 phone reports, 2026-11-13); now and then such a point lasts long
    /// enough to confirm as a second dart. Those points appear in the same frame as the real tip,
    /// while separate darts appeared 2.3 s or more apart. So a track that appears within this many
    /// usable frames of a reported dart's track, and within `sameLandingRadiusMM` of its tip, is
    /// part of that dart and never reported. Only for tracks the camera saw arrive (after
    /// `arrivalClearFrames` clear views): darts uncovered when a player steps away all count.
    /// The radius is wide (barrel points lay 13-51 mm from the tip) because the timing is what
    /// tells a barrel point from another dart.
    static let sameLandingFrames = 3
    static let sameLandingRadiusMM = 100.0
    /// Clear views in a row before a new track counts as seen arriving; tracks that appear while
    /// the view recovers (a player stepping away) were uncovered, not thrown, and all count.
    static let arrivalClearFrames = 3
    /// Detections weaker than this within `barrelAbsorbRadiusMM` of a barrel point belong to that
    /// dart, so a flickering barrel point does not come back later as a new dart. Stronger ones
    /// are a new dart landing there (real tips mostly scored 0.6-0.87 on the phone); once
    /// `barrelEscapeHits` of them started a track, its fainter detections are no longer absorbed. Barrel points
    /// never count as the dart still being in the board (removal and pull look at the tip).
    static let barrelAbsorbConfidence = 0.5
    static let barrelAbsorbRadiusMM = 20.0
    /// A track that starts within this distance of a barrel point which was detected in the last
    /// `barrelSeenRecentFrames` usable frames is that barrel point turning strong, at any
    /// confidence, and never becomes a dart: a new dart there would land behind a barrel the camera
    /// still sees, which hides its tip. On the phone (2026-11-16, 16-06-08) a barrel point 42 mm up
    /// a steep dart held at 0.35-0.6 for seconds and scored as a second dart. A barrel point that
    /// had gone unseen and comes back strong is still a new dart landing there (above).
    static let barrelPointRadiusMM = sameDartRadiusMM
    static let barrelSeenRecentFrames = 3
    /// Strong detections a candidate on a barrel point needs before its faint ones count. A barrel
    /// point on the phone crept up to 0.3-0.45 with lone spikes over 0.5; a new dart there is
    /// strong for several frames in a row.
    static let barrelEscapeHits = 2
    /// Tracks that appear in the first usable frames after the detector starts are background:
    /// darts left in the board from before are not scored for the first player. (Off for replay.)
    static let startupBaselineFrames = 3

    // MARK: Removal

    /// A dart of a closed visit counts as still there when any dart detection at this confidence
    /// or more lies within `confirmedDartRadiusMM` of it in the current frame.
    static let presenceFloor = 0.05
    /// Clear views in a row with none of the closed visit's darts before `.boardCleared`.
    static let removalFramesNeeded = 8
    /// While throwing, clear views in a row with none of the visit's darts (at any decoded
    /// confidence) and no candidate dart before the visit ends
    /// with `.visitEnded` and `.boardCleared` (its other darts missed the board and were never
    /// reported). Longer than the removal count: ending a visit by mistake costs a dart.
    static let pullFramesNeeded = 12
    /// A candidate track on the board blocks the pull only this many usable frames after it
    /// appeared: a real dart confirms well within it (13 frames at the 0.08 track floor), a false
    /// detection that never confirms must not keep a visit open forever.
    /// Known limits (review, 2026-11-12): a dart that flickers for longer than this before it turns
    /// steady can be lost to a pull (enter it by hand), and a false detection that keeps vanishing
    /// and reappearing in the board can keep a short visit open (tap Next). Both look the same as
    /// the other case at the moment of deciding, so a time bound is the trade-off.
    static let pullCandidateFrames = 30
    /// Three darts that all miss the board leave nothing to see pulled, so a visit with no dart
    /// reported ends when the player walks up to the board and back: at least `walkUpHiddenFrames`
    /// frames with the board hidden (occluded, or no board seen), then `pullFramesNeeded` clear
    /// views in a row with no candidate dart. It counts only after `walkUpClearFrames` clear views
    /// of the empty visit (about 5 s: time to throw), and only when no unreported candidate dart
    /// was on the board as the player stepped in front of it.
    /// In the 43 phone reports (2026-11-13 to 16), walk-ups hid the board for 6-82 frames; the two
    /// to fetch three missed darts came 104 and 118 clear views into the visit. Walking back
    /// after a clear came 2-14 clear views in, and setting the phone up shows moved or forming
    /// frames, not hidden ones.
    /// Known limit: someone else stepping in front of the board for over half a second, at least
    /// 5 s into a visit with no dart yet, ends it as three misses too (Undo reopens it).
    static let walkUpHiddenFrames = 6
    static let walkUpClearFrames = 50
    /// Clear views in the middle of a walk-up that still belong to it (the player moving at the
    /// board); after more, the next hidden frames are a new pass unless the first already counted.
    static let walkUpFlickerFrames = 3
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
