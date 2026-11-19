import CoreGraphics
import Foundation
import simd

/// The multi-frame logic of the RF-DETR detector, as a plain value type: no Core ML, no
/// threads, no clock. `DetectionEngine` feeds it one `FrameObservation` per processed frame and
/// the game's commands; unit tests feed it synthetic frames.
///
/// How it works:
/// - **Board lock.** The board does not move during a game. Calibration points of agreeing
///   frames are collected per point; the lock is the homography through their medians. It
///   forms after `lockFramesNeeded` agreeing frames (`.aligning` until then, `.ready` after).
///   When the points of several frames in a row disagree with it, the camera moved: unlock and
///   lock again. Darts are kept in board millimetres, so they survive a re-lock.
/// - **Usable and clear frames.** A frame is usable when at least four of its calibration points
///   agree with the lock; only usable frames feed darts. A frame is a clear view when nearly all
///   points seen at lock time agree; only clear views count a dart as missing or the board as
///   empty. Everything else (a player in front, a moving phone) is ignored.
/// - **Dart tracks.** Dart detections of usable frames, mapped to millimetres, are associated
///   with tracks by distance. A track becomes a dart when it persists with enough summed
///   confidence (`confirmEvidence`), so a dart the model sees at 0.1 in every frame is found,
///   and a one-frame flicker is not. Its tip is the median of its observations.
/// - **Visits.** A dart is reported once. Detections near darts already reported (this visit or a
///   closed visit still in the board) belong to them. After `endVisit()` nothing new is reported
///   until the closed visit's darts are absent from `removalFramesNeeded` clear views in a row.
///   Any usable frame that still shows one of those darts, clear view or not, starts the count over.
/// - **Misses.** Tips outside the double ring are never reported (`maxDartRadiusMM`). When the
///   darts of a visit with fewer than three are pulled (`pullFramesNeeded`), the tracker ends the
///   visit itself (`.visitEnded`, `.boardCleared`); the game counts the empty slots as misses.
///   A visit with no dart reported ends when the player walks up to the board and back
///   (`.emptyVisitEnded`, see `walkUpHiddenFrames`): all three missed.
/// Codable so a mistake report can store a checkpoint of its whole state (`DetectorRecorder`).
struct MultiFrameTracker: Codable {
    typealias Tuning = DetectorTuning

    struct ConfirmedDart: Equatable, Codable {
        let id: Int
        var boardMM: SIMD2<Double>
        var segment: Segment
        var confidence: Double
        /// Usable frame its track first appeared in, when the camera saw it arrive (see
        /// `sameLandingFrames`). Nil otherwise, and in checkpoints saved before it existed.
        var firstFrame: Int? = nil
        /// Where points on its barrel were seen (tracks that appeared with it); weak detections
        /// there belong to it (see `barrelAbsorbConfidence`).
        var barrelMM: [SIMD2<Double>]? = nil
        /// Usable frame it was reported in; nil in checkpoints saved before it existed.
        var reportedFrame: Int? = nil
        /// Recent usable frames in which its own tip was detected (within `stackedNeighbourMM`):
        /// a dart stacked next to it must be seen while this one still is (see `stackedDartFrames`).
        var tipSeenFrames: [Int]? = nil
        /// Per barrel point (same order as `barrelMM`), the last usable frame with a detection
        /// within `barrelPointRadiusMM` of it. Nil, or shorter than `barrelMM`, in checkpoints
        /// saved before it existed: those points count as not seen.
        var barrelSeenFrames: [Int]? = nil

        /// Adds a barrel point seen in usable frame `frame`.
        mutating func addBarrelPoint(_ point: SIMD2<Double>, frame: Int) {
            let points = barrelMM ?? []
            var frames = barrelSeenFrames ?? []
            // Points from an older checkpoint without a frame: never seen.
            while frames.count < points.count { frames.append(Int.min / 2) }
            barrelMM = points + [point]
            barrelSeenFrames = Array(frames.prefix(points.count)) + [frame]
        }

        /// A barrel point within `barrelPointRadiusMM` of `p` was detected at `frame` or later.
        func barrelSeen(near p: SIMD2<Double>, since frame: Int) -> Bool {
            let frames = barrelSeenFrames ?? []
            return (barrelMM ?? []).enumerated().contains { j, point in
                j < frames.count && frames[j] >= frame && simd_distance(point, p) <= Tuning.barrelPointRadiusMM
            }
        }

        /// A detection at its tip: this dart is still in the board.
        func coversTip(_ p: SIMD2<Double>) -> Bool {
            simd_distance(boardMM, p) <= Tuning.confirmedDartRadiusMM
        }

        /// A weak detection on its barrel: never a new dart, but no evidence that this dart is
        /// still there either (removal and pull use the tip only).
        func coversBarrel(_ p: SIMD2<Double>, confidence: Double) -> Bool {
            confidence < Tuning.barrelAbsorbConfidence
                && (barrelMM ?? []).contains { simd_distance($0, p) <= Tuning.barrelAbsorbRadiusMM }
        }
    }

    struct Observation: Equatable, Codable {
        var boardMM: SIMD2<Double>
        var confidence: Double
        /// `usableFrameCount` when seen.
        var frame: Int
    }

    struct Track: Equatable, Codable {
        let id: Int
        var observations: [Observation]
        let firstFrame: Int
        var missStreak = 0
        /// Predates a board clear or a reset, or lies on a dart's barrel point: never confirms.
        var isBackground: Bool
        /// Appeared next to a dart pulled moments ago (see `removedMemoryFrames`): does not
        /// confirm up to and including this usable frame, then counts as a normal track again.
        var suppressedUntil: Int? = nil
        /// Appeared after `arrivalClearFrames` clear views in a row: the camera saw it arrive
        /// rather than being uncovered (see `sameLandingFrames`). Nil in checkpoints saved before it existed.
        var seenArriving: Bool? = nil
        /// Started within `barrelPointRadiusMM` of a barrel point of a dart in the board that was
        /// detected in the frames just before: that barrel point, never a dart. Nil in checkpoints
        /// saved before it existed.
        var startedOnSeenBarrel: Bool? = nil
        /// Started in a cluttered frame (see `clutterEnterDarts`): a point of darts in a hand. Never
        /// confirms, is dropped at its first clear miss, and is never remembered as a barrel point.
        /// Nil in checkpoints saved before it existed.
        var startedInClutter: Bool? = nil

        /// Does not confirm now (background, or still suppressed).
        var isHeldBack: Bool { isBackground || suppressedUntil != nil }

        /// Component-wise median of the observations.
        var tipMM: SIMD2<Double> {
            SIMD2(median(observations.map(\.boardMM.x)), median(observations.map(\.boardMM.y)))
        }
    }

    enum Phase: Equatable, Codable {
        /// New darts are reported.
        case throwing
        /// `endVisit()` closed the visit; waiting for its darts to be pulled.
        case awaitingRemoval
        /// `reset()` with darts still in the board (confirmed, or unconfirmed tracks); nothing is
        /// reported until it is clear. With only unconfirmed tracks there is nothing to see
        /// pulled: the barrier lifts after `removalFramesNeeded` clear views, and those tracks
        /// stay background, so they never score in the new game.
        case resetBarrier
    }

    /// How the last frame was used.
    enum FrameUse: Equatable, Codable {
        case forming(streak: Int)
        case usable(clearView: Bool)
        case occluded
        case moved
        case noBoard
    }

    /// A calibration point of the last frame and whether it agreed with the lock.
    struct CalibrationReport: Equatable, Codable {
        var classIndex: Int
        var pixel: SIMD2<Double>
        var agrees: Bool
    }

    // MARK: State

    private(set) var status: BoardStatus = .searching
    /// Image pixels → board millimetres, while locked.
    private(set) var homography: Homography?
    var isLocked: Bool { homography != nil }
    /// Where the model should look next frame; nil for the whole frame.
    private(set) var crop: CGRect?
    private(set) var phase: Phase = .throwing
    private(set) var visitDarts: [ConfirmedDart] = []
    /// Darts of a visit reopened by `resumeVisit()`. They are still in the board and belong to this
    /// visit, so detections near them are not new darts, but they do not count towards
    /// `maxDartsPerVisit`: some of them may never have reached the game (events of a closed visit
    /// are dropped), and the game, not the tracker, knows how many darts the visit holds.
    private(set) var resumedDarts: [ConfirmedDart] = []
    /// Darts of closed visits still in the board.
    private(set) var oldDarts: [ConfirmedDart] = []
    private(set) var tracks: [Track] = []
    private(set) var usableFrameCount = 0

    // Debug view of the last frame.
    private(set) var lastFrameUse: FrameUse = .noBoard
    private(set) var lastCalibration: [CalibrationReport] = []
    private(set) var lockRMSErrorMM: Double?

    private var imageSize: CGSize = .zero
    private var history: [[SIMD2<Double>]] = Array(repeating: [], count: RFDetrDecoder.calibrationClasses)
    private var formingStreak = 0
    /// Most calibration points that agreed in one frame at the current camera pose; a clear view
    /// needs nearly this many. Kept across a re-lock at the same pose (see `lockedPose`).
    private var lockVisibleCount = 0
    /// The last lock, kept after unlocking: a new lock at the same pose keeps `lockVisibleCount`,
    /// so a board still half hidden when it re-locks does not become the new "clear" view.
    private var lockedPose: Homography?
    private var movedStreak = 0
    private var framesSinceUsable = 0
    private var framesWithoutBoard = 0
    private var pendingStatus: BoardStatus?
    private var pendingCount = 0
    /// The closed visit, restored by `resumeVisit()`. Nil once the board was cleared or reset.
    private var closedVisit: [ConfirmedDart]?
    private var removalStreak = 0
    /// Clear views in a row without any of the open visit's darts (see `pullFramesNeeded`).
    private var pullStreak = 0
    struct RemovedDart: Equatable, Codable {
        var boardMM: SIMD2<Double>
        var until: Int
    }
    private var removedDarts: [RemovedDart] = []
    /// Watches for the player walking up to the board while the visit has no dart (see
    /// `walkUpHiddenFrames`).
    struct WalkUp: Equatable, Codable {
        /// Clear views of the empty visit before the board was hidden.
        var clearFrames = 0
        /// Frames with the board hidden since then.
        var hiddenFrames = 0
        /// Clear views in a row since the board was last hidden.
        var clearAgain = 0
        /// The visit had been watched long enough, with no candidate dart on the board, when the
        /// board was first hidden.
        var counts = false
    }
    /// Nil while the visit has darts or is closed, and in checkpoints saved before it existed.
    private var walkUp: WalkUp?
    private var nextID = 1
    /// Clear views in a row up to the last processed frame (see `Track.seenArriving`).
    private var clearViewStreak: Int?
    /// Too many unexplained dart detections for a new candidate (see `clutterEnterDarts`). Nil when not, and in
    /// checkpoints saved before it existed.
    private var cluttered: Bool?
    /// Frames in a row with `clutterEnterDarts` or more, before `cluttered` (nil when none, and in
    /// checkpoints saved before it existed).
    private var busyStreak: Int?
    /// Darts already in the board when the detector starts are background (see `startupBaselineFrames`).
    private let ignoresDartsAtStart: Bool
    /// The camera's horizontal field of view (along the frame's long side), for `cameraPosition`.
    /// Nil when unknown, and in checkpoints saved before it existed.
    private(set) var cameraFieldOfViewDegrees: Double?

    init(ignoresDartsAtStart: Bool = true) {
        self.ignoresDartsAtStart = ignoresDartsAtStart
    }

    // MARK: Commands

    /// The visit is over: report nothing new until its darts were pulled, then `.boardCleared`.
    mutating func endVisit() {
        closedVisit = resumedDarts + visitDarts
        oldDarts += resumedDarts + visitDarts
        visitDarts = []
        resumedDarts = []
        if phase != .resetBarrier { phase = .awaitingRemoval }
        removalStreak = 0
        pullStreak = 0
    }

    /// Reopens the visit `endVisit()` closed: its darts count again as this visit's, new darts are reported.
    mutating func resumeVisit() {
        guard phase == .awaitingRemoval else { return }
        if let closed = closedVisit {
            let ids = Set(closed.map(\.id))
            // As they are now: their barrel points may have been seen since the visit closed.
            resumedDarts = closed.map { dart in oldDarts.first { $0.id == dart.id } ?? dart }
            oldDarts.removeAll { ids.contains($0.id) }
        } else {
            resumedDarts = []   // the board was seen clear since: nothing of that visit is left
        }
        visitDarts = []
        closedVisit = nil
        phase = .throwing
        removalStreak = 0
        pullStreak = 0
    }

    /// New game: forget the visit, and if darts may still be in the board, report nothing until it is clear.
    mutating func reset() {
        oldDarts += resumedDarts + visitDarts
        visitDarts = []
        resumedDarts = []
        closedVisit = nil
        // An unconfirmed track is also a dart that may still be in the board.
        let candidates = tracks.contains { !$0.isBackground }
        markTracksAsBackground()
        phase = oldDarts.isEmpty && !candidates ? .throwing : .resetBarrier
        removalStreak = 0
        pullStreak = 0
        walkUp = nil
    }

    /// The camera stopped and may have moved: lock again from scratch. Darts are kept.
    mutating func cameraRestarted() {
        unlock()
    }

    /// The camera's horizontal field of view in degrees (along the frame's long side); nil if unknown.
    mutating func setCameraFieldOfView(_ degrees: Double?) {
        cameraFieldOfViewDegrees = degrees
    }

    /// Where the camera stands, from the current lock (see `CameraPosition`). Nil while unlocked
    /// or when the lock is no plausible pinhole view.
    var cameraPosition: CameraPosition? {
        guard let imageFromBoard = homography?.inverse else { return nil }
        let focal = CameraPosition.focalPixels(imageSize: imageSize, fieldOfViewDegrees: cameraFieldOfViewDegrees)
        return CameraPosition(imageFromBoard: imageFromBoard, imageSize: imageSize, focalPixels: focal)
    }

    // MARK: Frames

    /// Processes one frame and returns the events it causes, in order.
    mutating func process(_ frame: FrameObservation) -> [DetectionEvent] {
        if frame.imageSize != imageSize {
            imageSize = frame.imageSize
            unlock()
            lockedPose = nil   // other pixel coordinates: no earlier pose to compare with
            lockVisibleCount = 0
        }
        let use = updateLock(frame.calibrationPoints)
        lastFrameUse = use
        var events: [DetectionEvent] = []
        if let status = updateStatus() { events.append(.status(status)) }
        // Darts in a hand (a pull): no new candidate starts in such a frame.
        let dartCount = unexplainedDartCount(frame)
        if cluttered == true {
            if dartCount <= Tuning.clutterLeaveDarts { cluttered = nil }
        } else {
            busyStreak = dartCount >= Tuning.clutterEnterDarts ? (busyStreak ?? 0) + 1 : nil
            if (busyStreak ?? 0) >= Tuning.clutterFramesNeeded {
                cluttered = true
                busyStreak = nil
                // Candidates born in the busy frame(s) just before are the hand's too.
                // (This frame is not counted yet: the streak's earlier frames are the last ones counted.)
                let firstBusy = usableFrameCount - (Tuning.clutterFramesNeeded - 2)
                for i in tracks.indices where tracks[i].firstFrame >= firstBusy && tracks[i].observations.count < Tuning.clutterFramesNeeded {
                    tracks[i].isBackground = true
                    tracks[i].startedInClutter = true
                }
            }
        }
        if case .usable(let clearView) = use, let h = homography {
            usableFrameCount += 1
            events += updateDarts(frame, homography: h, clearView: clearView, cluttered: cluttered == true)
        }
        // Not after this frame's events: a dart reported or a visit ended starts it over.
        if events.allSatisfy({ if case .status = $0 { return true } else { return false } }) {
            events += updateWalkUp(use)
        } else {
            walkUp = nil
        }
        clearViewStreak = use == .usable(clearView: true) ? (clearViewStreak ?? 0) + 1 : 0
        return events
    }

    /// Dart detections at `trackFloor` or more that are not at the tip or a remembered barrel point
    /// of a dart in the board (see `clutterEnterDarts`). Before a lock, all of them.
    private func unexplainedDartCount(_ frame: FrameObservation) -> Int {
        let detections = frame.darts(minConfidence: Tuning.trackFloor)
        guard let h = homography else { return detections.count }
        let known = visitDarts + resumedDarts + oldDarts
        return detections.filter { d in
            guard let p = h.apply(d.point) else { return true }
            return !known.contains { dart in
                dart.coversTip(p) || (dart.barrelMM ?? []).contains { simd_distance($0, p) <= Tuning.barrelAbsorbRadiusMM }
            }
        }.count
    }

    // MARK: Walking up without darts

    /// Ends a visit with no dart reported when the player walks up to the board and back (see
    /// `walkUpHiddenFrames`). Call after `updateDarts`, so the candidate checks see this frame.
    private mutating func updateWalkUp(_ use: FrameUse) -> [DetectionEvent] {
        guard phase == .throwing, visitDarts.isEmpty, resumedDarts.isEmpty else {
            walkUp = nil
            return []
        }
        var watch = walkUp ?? WalkUp()
        switch use {
        case .occluded, .noBoard:
            // Hidden again after more than a flicker of clear views, before it was hidden long
            // enough to count: a separate brief pass, counted on its own (review, 2026-11-16).
            if watch.hiddenFrames > 0, watch.hiddenFrames < Tuning.walkUpHiddenFrames,
               watch.clearAgain > Tuning.walkUpFlickerFrames {
                watch = WalkUp(clearFrames: watch.clearFrames + watch.clearAgain)
            }
            if watch.hiddenFrames == 0 {
                // A dart the camera saw but has not reported (too faint so far) may be on the
                // board: then the player may be fetching it, not three misses.
                let candidate = tracks.contains {
                    !$0.isHeldBack && $0.observations.count >= Tuning.confirmMinHits
                        && simd_length($0.tipMM) <= BoardGeometry.doubleOuterMM
                }
                watch.counts = watch.clearFrames >= Tuning.walkUpClearFrames && !candidate
            }
            watch.hiddenFrames += 1
            watch.clearAgain = 0
        case .usable(clearView: true):
            guard watch.hiddenFrames > 0 else {
                watch.clearFrames += 1
                break
            }
            // A dart landing as the view clears: the visit goes on. (Young candidates only, as for
            // a pull: a false detection that never confirms must not keep the visit open.)
            let dartArriving = tracks.contains {
                !$0.isHeldBack && $0.observations.last?.frame == usableFrameCount
                    && usableFrameCount - $0.firstFrame < Tuning.pullCandidateFrames
                    && simd_length($0.tipMM) <= BoardGeometry.doubleOuterMM
            }
            watch.clearAgain = dartArriving ? 0 : watch.clearAgain + 1
            if watch.clearAgain >= Tuning.pullFramesNeeded {
                if watch.counts && watch.hiddenFrames >= Tuning.walkUpHiddenFrames {
                    walkUp = nil
                    // Whatever is detected now was there before the next throw.
                    markTracksAsBackground()
                    return [.emptyVisitEnded]
                }
                // Someone passed by, or it came too early: keep watching the same visit.
                watch = WalkUp(clearFrames: watch.clearFrames + watch.clearAgain)
            }
        case .usable(clearView: false), .moved, .forming:
            watch.clearAgain = 0
        }
        walkUp = watch
        return []
    }

    // MARK: Board lock

    private mutating func updateLock(_ points: [Int: SIMD2<Double>]) -> FrameUse {
        framesWithoutBoard = points.count < 2 ? framesWithoutBoard + 1 : 0
        guard let lock = homography else { return formLock(points) }

        var agreeing: [Int: SIMD2<Double>] = [:]
        var disagreeing = 0
        lastCalibration = points.keys.sorted().map { c in
            let p = points[c]!
            let ok = lock.apply(p).map { simd_distance($0, BoardCalibration.targetsMM[c]) <= Tuning.pointAgreementMM } ?? false
            if ok { agreeing[c] = p } else { disagreeing += 1 }
            return CalibrationReport(classIndex: c, pixel: p, agrees: ok)
        }

        if agreeing.count >= 4 && agreeing.count >= disagreeing {
            movedStreak = 0
            framesSinceUsable = 0
            remember(pointsToLearn(points, agreeing: agreeing))
            if let refit = medianFit() {
                homography = refit.homography
                // The pose a later re-lock is compared with: the refined lock, not the one first
                // formed, which may have been off (see `pointsToLearn`).
                lockedPose = refit.homography
                lockRMSErrorMM = refit.rmsErrorMM
                updateCrop()
            }
            lockVisibleCount = max(lockVisibleCount, agreeing.count)
            return .usable(clearView: agreeing.count >= lockVisibleCount - Tuning.clearViewMissingPoints)
        }

        framesSinceUsable += 1
        if disagreeing >= 2 && disagreeing > agreeing.count {
            movedStreak += 1
            if movedStreak >= Tuning.movedFramesNeeded {
                unlock()
                _ = formLock(points)
            }
            return .moved
        }
        if framesSinceUsable >= Tuning.lostFramesBeforeUnlock { unlock() }
        return points.count < 2 ? .noBoard : .occluded
    }

    /// The points that refine a lock: those that agree with it, or, when this frame alone shows
    /// most of the board sharply (every point on one board within `relearnFitMM`) and that board
    /// keeps the agreeing points, all of its points.
    /// A lock formed while a player covered part of the board fits the visible part and can miss
    /// the rest by more than `pointAgreementMM`. Learning only from agreeing points, it never
    /// corrected: no clear view for whole visits (phone report, 2026-11-14).
    private func pointsToLearn(_ points: [Int: SIMD2<Double>], agreeing: [Int: SIMD2<Double>]) -> [Int: SIMD2<Double>] {
        guard points.count > agreeing.count, let fit = BoardCalibration.fit(points) else { return agreeing }
        let board = Set(fit.inlierClasses)
        guard board.count >= Tuning.relearnMinPoints, board.count > agreeing.count,
              agreeing.keys.filter({ !board.contains($0) }).count <= 1,
              board.allSatisfy({ c in
                  fit.homography.apply(points[c]!).map { simd_distance($0, BoardCalibration.targetsMM[c]) <= Tuning.relearnFitMM } ?? false
              })
        else { return agreeing }
        return points.filter { board.contains($0.key) }
    }

    /// Collects agreeing frames until the board can lock.
    private mutating func formLock(_ points: [Int: SIMD2<Double>]) -> FrameUse {
        guard let fit = BoardCalibration.fit(points) else {
            formingStreak = 0
            clearHistory()
            lastCalibration = points.keys.sorted().map { CalibrationReport(classIndex: $0, pixel: points[$0]!, agrees: false) }
            return points.count < 2 ? .noBoard : .occluded
        }
        let inliers = Dictionary(uniqueKeysWithValues: fit.inlierClasses.map { ($0, points[$0]!) })
        lastCalibration = points.keys.sorted().map { CalibrationReport(classIndex: $0, pixel: points[$0]!, agrees: inliers[$0] != nil) }
        remember(inliers)
        if let candidate = medianFit(), rms(of: inliers, under: candidate.homography) <= Tuning.lockAgreementMM {
            formingStreak += 1
            if formingStreak >= Tuning.lockFramesNeeded {
                homography = candidate.homography
                lockRMSErrorMM = candidate.rmsErrorMM
                let visible = candidate.inlierClasses.count
                if let previous = lockedPose, Self.samePose(previous, candidate.homography) {
                    lockVisibleCount = max(lockVisibleCount, visible)
                } else {
                    lockVisibleCount = visible
                }
                lockedPose = candidate.homography
                movedStreak = 0
                framesSinceUsable = 0
                updateCrop()
                return .usable(clearView: fit.inlierClasses.count >= lockVisibleCount - Tuning.clearViewMissingPoints)
            }
        } else {
            // The phone moved while forming: start over from this frame.
            clearHistory()
            remember(inliers)
            formingStreak = 1
        }
        return .forming(streak: formingStreak)
    }

    /// Two locks describe the same camera pose when every calibration target lands within
    /// `pointAgreementMM` of itself going through one lock to pixels and back through the other.
    private static func samePose(_ a: Homography, _ b: Homography) -> Bool {
        guard let aToImage = a.inverse else { return false }
        return BoardCalibration.targetsMM.allSatisfy { target in
            guard let pixel = aToImage.apply(target), let back = b.apply(pixel) else { return false }
            return simd_distance(back, target) <= Tuning.pointAgreementMM
        }
    }

    private mutating func unlock() {
        homography = nil
        crop = nil
        lockRMSErrorMM = nil
        formingStreak = 0
        movedStreak = 0
        framesSinceUsable = 0
        clearHistory()
    }

    private mutating func clearHistory() {
        history = Array(repeating: [], count: RFDetrDecoder.calibrationClasses)
    }

    private mutating func remember(_ points: [Int: SIMD2<Double>]) {
        for (c, p) in points {
            history[c].append(p)
            if history[c].count > Tuning.calibrationHistory { history[c].removeFirst() }
        }
    }

    /// Homography through the per-point medians of the history.
    private func medianFit() -> BoardCalibration.Fit? {
        var medians: [Int: SIMD2<Double>] = [:]
        for (c, list) in history.enumerated() where !list.isEmpty {
            medians[c] = SIMD2(median(list.map(\.x)), median(list.map(\.y)))
        }
        return BoardCalibration.fit(medians)
    }

    private func rms(of points: [Int: SIMD2<Double>], under h: Homography) -> Double {
        guard !points.isEmpty else { return .infinity }
        let sum = points.reduce(0.0) { total, entry in
            guard let mm = h.apply(entry.value) else { return .infinity }
            return total + simd_distance_squared(mm, BoardCalibration.targetsMM[entry.key])
        }
        return (sum / Double(points.count)).squareRoot()
    }

    /// The board's bounding box in the image (from the lock) plus a margin, as the offline two-pass evaluation cropped.
    private mutating func updateCrop() {
        guard let inverse = homography?.inverse, imageSize.width > 0 else { crop = nil; return }
        var minP = SIMD2(Double.infinity, .infinity), maxP = -minP
        for i in 0..<72 {
            let a = Double(i) * .pi / 36
            guard let p = inverse.apply(SIMD2(cos(a), sin(a)) * Tuning.boardEdgeMM) else { crop = nil; return }
            minP = simd_min(minP, p); maxP = simd_max(maxP, p)
        }
        let margin = (maxP - minP) * Tuning.cropMargin
        let full = CGRect(origin: .zero, size: imageSize)
        let box = CGRect(x: minP.x - margin.x, y: minP.y - margin.y,
                         width: maxP.x - minP.x + 2 * margin.x, height: maxP.y - minP.y + 2 * margin.y).intersection(full)
        guard !box.isNull, box.width >= Tuning.minimumCropSide, box.height >= Tuning.minimumCropSide else { crop = nil; return }
        if let current = crop {
            let limit = Tuning.cropUpdateFraction * Double(max(current.width, current.height))
            let moved = max(abs(box.minX - current.minX), abs(box.minY - current.minY),
                            abs(box.maxX - current.maxX), abs(box.maxY - current.maxY))
            if moved <= limit { return }
        }
        crop = box.integral.intersection(full)
    }

    // MARK: Status

    private mutating func updateStatus() -> BoardStatus? {
        let raw: BoardStatus
        if isLocked {
            raw = framesSinceUsable >= Tuning.occludedFramesBeforeAligning ? .aligning : .ready
        } else {
            raw = framesWithoutBoard >= Tuning.emptyFramesBeforeSearching ? .searching : .aligning
        }
        if raw == status { pendingStatus = nil; pendingCount = 0; return nil }
        if raw == pendingStatus { pendingCount += 1 } else { pendingStatus = raw; pendingCount = 1 }
        guard pendingCount >= Tuning.statusDebounceFrames else { return nil }
        status = raw
        pendingStatus = nil
        pendingCount = 0
        return raw
    }

    // MARK: Darts

    /// `cluttered`: see `clutterEnterDarts`; tracks that start in such a frame never confirm.
    private mutating func updateDarts(_ frame: FrameObservation, homography h: Homography, clearView: Bool,
                                      cluttered: Bool) -> [DetectionEvent] {
        var events: [DetectionEvent] = []
        let frameIndex = usableFrameCount
        let camera = cameraPosition
        removedDarts.removeAll { $0.until < frameIndex }
        for i in tracks.indices where (tracks[i].suppressedUntil ?? .max) < frameIndex {
            tracks[i].suppressedUntil = nil
        }

        // Detections in board millimetres.
        let seen: [Observation] = frame.darts(minConfidence: min(Tuning.presenceFloor, Tuning.trackFloor)).compactMap { d in
            guard let mm = h.apply(d.point), simd_length(mm) <= Tuning.maxDartRadiusMM else { return nil }
            return Observation(boardMM: mm, confidence: d.confidence, frame: frameIndex)
        }.sorted { $0.confidence > $1.confidence }

        // 1. Detections near darts already reported belong to them.
        let openVisit = visitDarts + resumedDarts
        func nearOpenVisit(_ p: SIMD2<Double>) -> Bool { openVisit.contains { $0.coversTip(p) } }
        // For the pull, any decoded detection of a visit dart, however faint, means it is still there.
        let visitDartSeen = !openVisit.isEmpty && frame.darts(minConfidence: Tuning.decodeFloor)
            .contains { h.apply($0.point).map(nearOpenVisit) ?? false }
        // A weak detection on a known barrel point is that dart's barrel, unless strong detections
        // already started a candidate there: a new dart landing on that spot (strong for a few
        // frames, where a barrel point only spikes now and then).
        func onBarrel(_ o: Observation) -> Bool {
            guard (openVisit + oldDarts).contains(where: { $0.coversBarrel(o.boardMM, confidence: o.confidence) }) else { return false }
            return !tracks.contains { t in
                !t.isHeldBack && simd_distance(t.tipMM, o.boardMM) <= Tuning.associationRadiusMM
                    && t.observations.filter { $0.confidence >= Tuning.barrelAbsorbConfidence }.count >= Tuning.barrelEscapeHits
            }
        }
        // Each dart of the open visit claims its nearest detection: that is its tip. Another strong
        // detection beside it (farther than `sameDartRadiusMM`) may be a dart stacked next to it,
        // so it goes on to the tracks; confirming it takes `isStackedDart`.
        var claimed = Set<Int>()
        for dart in openVisit {
            guard let (index, distance) = seen.indices.map({ ($0, simd_distance(seen[$0].boardMM, dart.boardMM)) })
                .filter({ $0.1 <= Tuning.confirmedDartRadiusMM }).min(by: { $0.1 < $1.1 }) else { continue }
            claimed.insert(index)
            if distance <= Tuning.stackedNeighbourMM { noteTipSeen(of: dart.id, frame: frameIndex) }
        }
        func belongsToOpenVisit(_ index: Int) -> Bool {
            let o = seen[index]
            if claimed.contains(index) || o.confidence < Tuning.stackedDartConfidence { return nearOpenVisit(o.boardMM) }
            return openVisit.contains { simd_distance($0.boardMM, o.boardMM) <= Tuning.sameDartRadiusMM }
        }
        var free: [Observation] = []
        var oldDartSeen = false
        for (index, o) in seen.enumerated() {
            if belongsToOpenVisit(index) { continue }
            if oldDarts.contains(where: { $0.coversTip(o.boardMM) }) {
                oldDartSeen = true
                continue
            }
            if onBarrel(o) { continue }
            free.append(o)
        }

        // 2. Removal: the closed visit's darts must be absent from several clear views in a row.
        // Seeing one of them in any usable frame, even a partial view, starts over.
        var removalComplete = false
        if phase != .throwing || !oldDarts.isEmpty {
            if oldDartSeen {
                removalStreak = 0
            } else if clearView {
                removalStreak += 1
                removalComplete = removalStreak >= Tuning.removalFramesNeeded
            }
        }

        // 3. Associate the rest with tracks.
        var matched = Set<Int>()
        for o in free where o.confidence >= Tuning.trackFloor {
            let nearest = tracks.indices
                .filter { !matched.contains(tracks[$0].id) && Self.mayJoin(o.boardMM, trackTip: tracks[$0].tipMM) }
                .map { ($0, simd_distance(tracks[$0].tipMM, o.boardMM)) }
                .filter { $0.1 <= Tuning.associationRadiusMM }
                .min { $0.1 < $1.1 }
            if let (index, _) = nearest {
                tracks[index].observations.append(o)
                if tracks[index].observations.count > Tuning.tipObservationsKept { tracks[index].observations.removeFirst() }
                matched.insert(tracks[index].id)
            } else {
                // Next to a dart pulled moments ago: maybe that dart, hidden by a hand during the
                // clear. Held back until the memory of it ends, then judged like any other track,
                // so a new dart in the same bed still scores.
                let suppressedUntil = removedDarts
                    .filter { simd_distance($0.boardMM, o.boardMM) <= Tuning.confirmedDartRadiusMM }
                    .map(\.until).max()
                // At startup, darts already in the board; in a cluttered frame, darts in a hand.
                let background = ignoresDartsAtStart && frameIndex <= Tuning.startupBaselineFrames || cluttered
                // On a barrel point seen until now: that barrel point turning strong, not a new dart.
                let onSeenBarrel = (openVisit + oldDarts).contains {
                    $0.barrelSeen(near: o.boardMM, since: frameIndex - Tuning.barrelSeenRecentFrames)
                }
                let track = Track(id: nextID, observations: [o], firstFrame: frameIndex, isBackground: background,
                                  suppressedUntil: suppressedUntil,
                                  seenArriving: (clearViewStreak ?? 0) >= Tuning.arrivalClearFrames,
                                  startedOnSeenBarrel: onSeenBarrel, startedInClutter: cluttered ? true : nil)
                nextID += 1
                tracks.append(track)
                matched.insert(track.id)
            }
        }
        for i in tracks.indices {
            if matched.contains(tracks[i].id) { tracks[i].missStreak = 0 } else if clearView { tracks[i].missStreak += 1 }
        }
        tracks.removeAll {
            $0.missStreak > ($0.startedInClutter == true ? 0 : $0.isHeldBack ? Tuning.backgroundForgetFrames : Tuning.maxMissStreak)
        }
        noteBarrelsSeen(seen, frame: frameIndex)

        // Pulled before three darts were reported (the others missed the board): none of the
        // visit's darts and no candidate dart in this clear view, for several in a row.
        var pulled = false
        if phase == .throwing && !openVisit.isEmpty {
            // A young candidate on the board may be a dart still building evidence. One that has
            // not confirmed by `pullCandidateFrames`, or lies outside the board, never will.
            let candidateSeen = tracks.contains {
                matched.contains($0.id) && !$0.isHeldBack
                    && usableFrameCount - $0.firstFrame < Tuning.pullCandidateFrames
                    && simd_length($0.tipMM) <= BoardGeometry.doubleOuterMM
            }
            if visitDartSeen || candidateSeen {
                pullStreak = 0
            } else if clearView {
                pullStreak += 1
                pulled = pullStreak >= Tuning.pullFramesNeeded
            }
        } else {
            pullStreak = 0
        }

        // Finish the removal after this frame's detections joined tracks: a dart first seen on the
        // clearing frame was thrown before the clear, so it becomes background like the rest.
        if removalComplete { events += finishRemoval() }
        if pulled { return events + finishPull() }

        // 4. Confirm persistent tracks.
        guard phase == .throwing else { return events }
        let ready = tracks.filter { !$0.isHeldBack && isConfirmable($0) }
            .sorted { evidence(of: $0) > evidence(of: $1) }
        for track in ready where visitDarts.count < Tuning.maxDartsPerVisit {
            // Became part of a dart confirmed earlier in this loop.
            guard let current = tracks.first(where: { $0.id == track.id }), !current.isHeldBack else { continue }
            let tip = track.tipMM
            let segment = BoardGeometry.segment(at: BoardPoint(millimetres: tip))
            // Outside the double ring: a barrel or flight seen from a steep angle, or a real miss.
            // Never reported; the track stays and scores if its tip settles inside.
            if segment == .miss { continue }
            // Beside a dart of this visit (within `stackedZoneMM`): a second dart stacked next to it
            // only on the stricter evidence of `isStackedDart`; until then the track waits.
            let open = visitDarts + resumedDarts
            if let neighbour = open.filter({ simd_distance($0.boardMM, tip) <= Tuning.stackedZoneMM })
                .min(by: { simd_distance($0.boardMM, tip) < simd_distance($1.boardMM, tip) }),
               simd_distance(neighbour.boardMM, tip) > Tuning.sameDartRadiusMM,
               !oldDarts.contains(where: { simd_distance($0.boardMM, tip) <= Tuning.confirmedDartRadiusMM }),
               !isStackedDart(track, beside: neighbour) {
                continue
            }
            // Started on a barrel point that was still being seen: part of that dart (see
            // `barrelPointRadiusMM`). Kept as background, so its later detections join it and a
            // new track there does not keep blocking a pull.
            if track.startedOnSeenBarrel == true, let i = tracks.firstIndex(where: { $0.id == track.id }) {
                tracks[i].isBackground = true
                continue
            }
            tracks.removeAll { $0.id == track.id }
            // Drifted onto a dart already reported: it is that dart.
            if oldDarts.contains(where: { simd_distance($0.boardMM, tip) <= Tuning.confirmedDartRadiusMM })
                || open.contains(where: { simd_distance($0.boardMM, tip) <= Tuning.sameDartRadiusMM }) { continue }
            // Appeared together with a dart already reported: a point on its barrel, not a new dart.
            if let i = visitDarts.firstIndex(where: { Self.landedTogether(track, $0, camera: camera) }) {
                visitDarts[i].addBarrelPoint(tip, frame: frameIndex)
                continue
            }
            if let i = resumedDarts.firstIndex(where: { Self.landedTogether(track, $0, camera: camera) }) {
                resumedDarts[i].addBarrelPoint(tip, frame: frameIndex)
                continue
            }
            var dart = ConfirmedDart(id: track.id, boardMM: tip, segment: segment,
                                     confidence: track.observations.map(\.confidence).max() ?? 0,
                                     firstFrame: track.seenArriving == true ? track.firstFrame : nil,
                                     reportedFrame: frameIndex)
            // The other tracks that appeared with it are its barrel: they never become darts, and are
            // remembered as barrel points, even when seen only once: such points come back (phone,
            // 2026-11-18: a twin seen once as its dart confirmed, back at 0.5-0.7 a frame later;
            // 2026-11-16: a flicker 36 mm away, back faintly for seconds). Remembering them can hide a
            // faint real dart landing on that spot later (`coversBarrel`); forgetting them cost real
            // scores in both recordings.
            let barrel = tracks.filter { Self.landedTogether($0, dart, camera: camera) }
            for point in barrel where point.startedInClutter != true { dart.addBarrelPoint(point.tipMM, frame: frameIndex) }
            tracks.removeAll { t in barrel.contains { $0.id == t.id } }
            visitDarts.append(dart)
            events.append(.dartDetected(DetectedDart(segment: dart.segment, boardPosition: BoardPoint(millimetres: tip),
                                                     confidence: dart.confidence)))
        }
        return events
    }

    /// A track beside a reported dart is a second dart stacked next to it, not a duplicate of it
    /// (see `stackedDartFrames`): it appeared after that dart was reported, and in its last usable
    /// frames in a row it was strong, still, and seen together with that dart's own tip.
    /// Past `confirmedDartRadiusMM` (out to `stackedZoneMM`) the test is lighter: each frame at
    /// `stackedOuterConfidence` or more, and the dart's own tip need not be seen (the new dart may
    /// hide it); there a duplicate only shows up flickering, and the old tracker scored such tracks freely.
    func isStackedDart(_ track: Track, beside dart: ConfirmedDart) -> Bool {
        guard let reported = dart.reportedFrame, track.firstFrame > reported else { return false }
        let outer = simd_distance(track.tipMM, dart.boardMM) > Tuning.confirmedDartRadiusMM
        let minimum = outer ? Tuning.stackedOuterConfidence : Tuning.stackedDartConfidence
        // Something that appeared with the dart at this spot was recorded as part of it (see
        // `landedTogether`); its later detections start a new track but are still that dart.
        if (dart.barrelMM ?? []).contains(where: { simd_distance($0, track.tipMM) <= Tuning.sameDartRadiusMM }) { return false }
        let recent = track.observations.suffix(Tuning.stackedDartFrames)
        guard recent.count == Tuning.stackedDartFrames, recent.last?.frame == usableFrameCount,
              zip(recent, recent.dropFirst()).allSatisfy({ $1.frame == $0.frame + 1 }),
              recent.allSatisfy({ $0.confidence >= minimum })
        else { return false }
        let centre = SIMD2(median(recent.map(\.boardMM.x)), median(recent.map(\.boardMM.y)))
        guard recent.allSatisfy({ simd_distance($0.boardMM, centre) <= Tuning.stackedDartSpreadMM }) else { return false }
        if outer { return true }
        let frames = Set(recent.map(\.frame))
        let together = (dart.tipSeenFrames ?? []).filter { frames.contains($0) }.count
        return 2 * together >= Tuning.stackedDartFrames
    }

    /// Notes which darts in the board had a barrel point detected in usable frame `frame`.
    private mutating func noteBarrelsSeen(_ seen: [Observation], frame: Int) {
        func note(_ darts: inout [ConfirmedDart]) {
            for i in darts.indices {
                let points = darts[i].barrelMM ?? []
                var frames = darts[i].barrelSeenFrames ?? []
                while frames.count < points.count { frames.append(Int.min / 2) }
                for (j, point) in points.enumerated()
                where seen.contains(where: { simd_distance($0.boardMM, point) <= Tuning.barrelPointRadiusMM }) {
                    frames[j] = frame
                }
                if !points.isEmpty { darts[i].barrelSeenFrames = frames }
            }
        }
        note(&visitDarts)
        note(&resumedDarts)
        note(&oldDarts)
    }

    /// Notes that the tip of reported dart `id` was seen in usable frame `frame`.
    private mutating func noteTipSeen(of id: Int, frame: Int) {
        func note(_ dart: inout ConfirmedDart) {
            var frames = dart.tipSeenFrames ?? []
            frames.append(frame)
            if frames.count > 2 * Tuning.stackedDartFrames { frames.removeFirst(frames.count - 2 * Tuning.stackedDartFrames) }
            dart.tipSeenFrames = frames
        }
        if let i = visitDarts.firstIndex(where: { $0.id == id }) { note(&visitDarts[i]) }
        if let i = resumedDarts.firstIndex(where: { $0.id == id }) { note(&resumedDarts[i]) }
    }

    /// One dart lands at a time: a track that first appeared within `sameLandingFrames` of a
    /// dart's track, within `sameLandingRadiusMM` of it or where that dart's body can appear
    /// (`CameraPosition.bodyZoneContains`), is part of that dart: the model also fires along the
    /// barrel and flight of a dart that just landed (phone tests 2026-11-13 and -18).
    /// So is a twin of its tip that starts a little later (`twinRadiusMM`, `twinFramesAfter`).
    static func landedTogether(_ track: Track, _ dart: ConfirmedDart, camera: CameraPosition?) -> Bool {
        guard let landed = dart.firstFrame, track.seenArriving == true, track.id != dart.id else { return false }
        let delta = track.firstFrame - landed
        let tip = track.tipMM
        if delta >= -Tuning.sameLandingFrames, delta <= Tuning.twinFramesAfter,
           simd_distance(tip, dart.boardMM) <= Tuning.twinRadiusMM,
           (track.observations.map(\.confidence).max() ?? 0) < Tuning.twinMaxConfidence { return true }
        guard abs(delta) <= Tuning.sameLandingFrames else { return false }
        // No second throw lands this close in time, so the near disc always applies; the camera
        // only reaches further, along the body behind the tip.
        if simd_distance(tip, dart.boardMM) <= Tuning.sameLandingRadiusMM { return true }
        guard let camera else { return false }
        // Its body, or its tip when the body confirmed first (the tip track started a frame or two
        // later, or was fainter): one dart either way. Whichever confirms first is reported; holding
        // a strong point back for a fainter one in front of it cost real darts on the phone
        // recordings (faint points on the camera side of real tips are common).
        return camera.bodyZoneContains(tip, tip: dart.boardMM) || camera.bodyZoneContains(dart.boardMM, tip: tip)
    }


    /// An observation joins a track only on the same side of the outer double wire, unless both
    /// lie close to it: a barrel or flight seen past the ring must not pull a real double's median
    /// outside the board, while a tip that wobbles across the wire stays one track.
    static func mayJoin(_ observation: SIMD2<Double>, trackTip: SIMD2<Double>) -> Bool {
        let ring = BoardGeometry.doubleOuterMM
        let o = simd_length(observation), t = simd_length(trackTip)
        if (o > ring) == (t > ring) { return true }
        return abs(o - ring) <= Tuning.ringJoinMarginMM && abs(t - ring) <= Tuning.ringJoinMarginMM
    }

    /// Summed confidence within the evidence window.
    func evidence(of track: Track) -> Double {
        track.observations.filter { $0.frame > usableFrameCount - Tuning.evidenceWindow }.reduce(0) { $0 + $1.confidence }
    }

    func isConfirmable(_ track: Track) -> Bool {
        let window = track.observations.filter { $0.frame > usableFrameCount - Tuning.evidenceWindow }
        let age = usableFrameCount - track.firstFrame + 1
        let ratio = Double(window.count) / Double(min(age, Tuning.evidenceWindow))
        guard window.count >= Tuning.confirmMinHits,
              window.reduce(0, { $0 + $1.confidence }) >= Tuning.confirmEvidence,
              ratio >= Tuning.confirmMinHitRatio,
              track.observations.contains(where: { $0.confidence >= Tuning.confirmMinPeakConfidence })
        else { return false }
        // Near a wire, wait for a few more frames before trusting the median.
        if track.observations.count < Tuning.wireExtraHits,
           BoardGeometry.distanceToNearestWireMM(BoardPoint(millimetres: track.tipMM)) < Tuning.wireMarginMM {
            return false
        }
        return true
    }

    private mutating func finishRemoval() -> [DetectionEvent] {
        let wasClosed = phase == .awaitingRemoval
        let until = usableFrameCount + Tuning.removedMemoryFrames
        removedDarts += oldDarts.map { RemovedDart(boardMM: $0.boardMM, until: until) }
        oldDarts = []
        removalStreak = 0
        guard phase != .throwing else { return [] }   // a reopened visit's older darts were pulled: nothing to report
        // Whatever is still detected now was there before the next throw: never report it.
        markTracksAsBackground()
        closedVisit = nil
        phase = .throwing
        return wasClosed ? [.boardCleared] : []
    }

    /// The open visit's darts were pulled: end the visit. Like a removal, whatever is still
    /// detected now was there before the next throw and is never reported.
    private mutating func finishPull() -> [DetectionEvent] {
        let until = usableFrameCount + Tuning.removedMemoryFrames
        removedDarts += (resumedDarts + visitDarts).map { RemovedDart(boardMM: $0.boardMM, until: until) }
        visitDarts = []
        resumedDarts = []
        pullStreak = 0
        markTracksAsBackground()
        return [.visitEnded, .boardCleared]
    }

    private mutating func markTracksAsBackground() {
        for i in tracks.indices { tracks[i].isBackground = true }
    }
}

/// Median of a non-empty list (mean of the middle two for even counts).
func median(_ values: [Double]) -> Double {
    precondition(!values.isEmpty)
    let s = values.sorted()
    let mid = s.count / 2
    return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
}
