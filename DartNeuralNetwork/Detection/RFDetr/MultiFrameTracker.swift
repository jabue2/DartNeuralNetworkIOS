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
struct MultiFrameTracker {
    typealias Tuning = DetectorTuning

    struct ConfirmedDart: Equatable {
        let id: Int
        var boardMM: SIMD2<Double>
        var segment: Segment
        var confidence: Double
    }

    struct Observation: Equatable {
        var boardMM: SIMD2<Double>
        var confidence: Double
        /// `usableFrameCount` when seen.
        var frame: Int
    }

    struct Track: Equatable {
        let id: Int
        var observations: [Observation]
        let firstFrame: Int
        var missStreak = 0
        /// Predates a board clear or a reset: never confirms.
        var isBackground: Bool
        /// Appeared next to a dart pulled moments ago (see `removedMemoryFrames`): does not
        /// confirm up to and including this usable frame, then counts as a normal track again.
        var suppressedUntil: Int? = nil

        /// Does not confirm now (background, or still suppressed).
        var isHeldBack: Bool { isBackground || suppressedUntil != nil }

        /// Component-wise median of the observations.
        var tipMM: SIMD2<Double> {
            SIMD2(median(observations.map(\.boardMM.x)), median(observations.map(\.boardMM.y)))
        }
    }

    enum Phase: Equatable {
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
    enum FrameUse: Equatable {
        case forming(streak: Int)
        case usable(clearView: Bool)
        case occluded
        case moved
        case noBoard
    }

    /// A calibration point of the last frame and whether it agreed with the lock.
    struct CalibrationReport: Equatable {
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
    private var removedDarts: [(boardMM: SIMD2<Double>, until: Int)] = []
    private var nextID = 1
    /// Darts already in the board when the detector starts are background (see `startupBaselineFrames`).
    private let ignoresDartsAtStart: Bool

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
            oldDarts.removeAll { ids.contains($0.id) }
            resumedDarts = closed
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
    }

    /// The camera stopped and may have moved: lock again from scratch. Darts are kept.
    mutating func cameraRestarted() {
        unlock()
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
        if case .usable(let clearView) = use, let h = homography {
            usableFrameCount += 1
            events += updateDarts(frame, homography: h, clearView: clearView)
        }
        return events
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
            remember(agreeing)
            if let refit = medianFit() {
                homography = refit.homography
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

    private mutating func updateDarts(_ frame: FrameObservation, homography h: Homography, clearView: Bool) -> [DetectionEvent] {
        var events: [DetectionEvent] = []
        let frameIndex = usableFrameCount
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
        func nearOpenVisit(_ p: SIMD2<Double>) -> Bool {
            openVisit.contains { simd_distance($0.boardMM, p) <= Tuning.confirmedDartRadiusMM }
        }
        // For the pull, any decoded detection of a visit dart, however faint, means it is still there.
        let visitDartSeen = !openVisit.isEmpty && frame.darts(minConfidence: Tuning.decodeFloor)
            .contains { h.apply($0.point).map(nearOpenVisit) ?? false }
        var free: [Observation] = []
        var oldDartSeen = false
        for o in seen {
            if nearOpenVisit(o.boardMM) { continue }
            if oldDarts.contains(where: { simd_distance($0.boardMM, o.boardMM) <= Tuning.confirmedDartRadiusMM }) {
                oldDartSeen = true
                continue
            }
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
                let atStart = ignoresDartsAtStart && frameIndex <= Tuning.startupBaselineFrames
                let track = Track(id: nextID, observations: [o], firstFrame: frameIndex, isBackground: atStart,
                                  suppressedUntil: suppressedUntil)
                nextID += 1
                tracks.append(track)
                matched.insert(track.id)
            }
        }
        for i in tracks.indices {
            if matched.contains(tracks[i].id) { tracks[i].missStreak = 0 } else if clearView { tracks[i].missStreak += 1 }
        }
        tracks.removeAll { $0.missStreak > ($0.isHeldBack ? Tuning.backgroundForgetFrames : Tuning.maxMissStreak) }

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
            let tip = track.tipMM
            let segment = BoardGeometry.segment(at: BoardPoint(millimetres: tip))
            // Outside the double ring: a barrel or flight seen from a steep angle, or a real miss.
            // Never reported; the track stays and scores if its tip settles inside.
            if segment == .miss { continue }
            tracks.removeAll { $0.id == track.id }
            // Drifted onto a dart already reported: it is that dart.
            if (visitDarts + resumedDarts + oldDarts).contains(where: { simd_distance($0.boardMM, tip) <= Tuning.confirmedDartRadiusMM }) { continue }
            let dart = ConfirmedDart(id: track.id, boardMM: tip, segment: segment,
                                     confidence: track.observations.map(\.confidence).max() ?? 0)
            visitDarts.append(dart)
            events.append(.dartDetected(DetectedDart(segment: dart.segment, boardPosition: BoardPoint(millimetres: tip),
                                                     confidence: dart.confidence)))
        }
        return events
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
              ratio >= Tuning.confirmMinHitRatio else { return false }
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
        removedDarts += oldDarts.map { ($0.boardMM, until) }
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
        removedDarts += (resumedDarts + visitDarts).map { ($0.boardMM, until) }
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
