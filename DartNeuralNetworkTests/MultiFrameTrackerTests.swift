import XCTest
import simd
@testable import DartNeuralNetwork

/// Synthetic camera frames: a board seen through a known homography, with calibration points
/// and darts at chosen confidences.
private struct Scene {
    var camera = HomographyTests.camera   // board mm → image pixels
    var imageSize = CGSize(width: 1080, height: 1440)
    var rng = SeededRandom(seed: 5)
    var noisePixels = 0.4

    struct Dart { var mm: SIMD2<Double>; var confidence: Double }

    /// One frame. `calibration` lists the visible calibration classes.
    mutating func frame(darts: [Dart] = [], calibration: Set<Int> = Set(0..<12)) -> FrameObservation {
        var detections: [ModelDetection] = []
        for c in calibration.sorted() {
            detections.append(ModelDetection(classIndex: c, point: pixel(BoardCalibration.targetsMM[c]), confidence: 0.85))
        }
        for d in darts {
            detections.append(ModelDetection(classIndex: RFDetrDecoder.dartClass, point: pixel(d.mm), confidence: d.confidence))
        }
        return FrameObservation(imageSize: imageSize, detections: detections)
    }

    private mutating func pixel(_ mm: SIMD2<Double>) -> SIMD2<Double> {
        camera.apply(mm)! + SIMD2(rng.gaussian(), rng.gaussian()) * noisePixels
    }
}

/// Millimetres of a point in the middle of a bed.
private func mm(_ segment: Segment, angle: Double = 0) -> SIMD2<Double> {
    BoardGeometry.point(in: segment, angleOffset: angle)!.millimetres
}

final class MultiFrameTrackerTests: XCTestCase {
    private var scene = Scene()
    private var tracker = MultiFrameTracker(ignoresDartsAtStart: false)
    private var events: [DetectionEvent] = []

    private var darts: [DetectedDart] {
        events.compactMap { if case .dartDetected(let d) = $0 { return d } else { return nil } }
    }
    private var clears: Int { events.filter { $0 == .boardCleared }.count }

    /// Runs `count` frames and collects their events.
    private func run(_ count: Int, darts: [Scene.Dart] = [], calibration: Set<Int> = Set(0..<12)) {
        for _ in 0..<count { events += tracker.process(scene.frame(darts: darts, calibration: calibration)) }
    }

    private func lock() {
        run(DetectorTuning.lockFramesNeeded + 2)
        XCTAssertTrue(tracker.isLocked)
        XCTAssertEqual(tracker.status, .ready)
    }

    // MARK: Board lock

    func testLocksAfterSteadyFramesAndCropsToTheBoard() throws {
        run(1)
        XCTAssertFalse(tracker.isLocked)
        run(DetectorTuning.lockFramesNeeded)
        XCTAssertTrue(tracker.isLocked)
        let statuses = events.compactMap { if case .status(let s) = $0 { return s } else { return nil } }
        XCTAssertEqual(statuses.last, .ready)
        XCTAssertTrue(statuses.contains(.aligning))
        // The lock maps the board centre within a millimetre.
        let h = try XCTUnwrap(tracker.homography)
        XCTAssertLessThan(simd_length(h.apply(HomographyTests.camera.apply(.zero)!)!), 1)
        // The crop contains the whole board edge and not much more.
        let crop = try XCTUnwrap(tracker.crop)
        for i in 0..<36 {
            let a = Double(i) * .pi / 18
            let p = HomographyTests.camera.apply(SIMD2(cos(a), sin(a)) * 225)!
            XCTAssertTrue(crop.insetBy(dx: -2, dy: -2).contains(CGPoint(x: p.x, y: p.y)))
        }
        XCTAssertLessThan(crop.width, scene.imageSize.width)
    }

    func testNoBoardIsSearching() {
        tracker = MultiFrameTracker()
        run(1)
        for _ in 0..<10 { events += tracker.process(scene.frame(calibration: [])) }
        XCTAssertEqual(tracker.status, .searching)
        XCTAssertFalse(tracker.isLocked)
    }

    func testCameraMovementRelocksAndKeepsDarts() throws {
        lock()
        run(8, darts: [.init(mm: mm(.triple(20)), confidence: 0.6)])
        XCTAssertEqual(darts.count, 1)
        // The phone is bumped: the whole image shifts and turns a little.
        scene.camera = scene.camera.then(Homography(rows: [0.99, -0.05, 70, 0.05, 0.99, -40, 0, 0, 1]))
        run(DetectorTuning.movedFramesNeeded, darts: [.init(mm: mm(.triple(20)), confidence: 0.6)])
        XCTAssertFalse(tracker.isLocked, "moving the camera drops the old lock")
        run(1, darts: [.init(mm: mm(.triple(20)), confidence: 0.6)])
        XCTAssertEqual(tracker.status, .aligning)
        run(DetectorTuning.lockFramesNeeded + 3, darts: [.init(mm: mm(.triple(20)), confidence: 0.6)])
        XCTAssertTrue(tracker.isLocked)
        XCTAssertEqual(tracker.status, .ready)
        let h = try XCTUnwrap(tracker.homography)
        XCTAssertLessThan(simd_length(h.apply(scene.camera.apply(.zero)!)!), 1, "locked to the new view")
        XCTAssertEqual(darts.count, 1, "the same dart is not reported again after the re-lock")
        run(10, darts: [.init(mm: mm(.triple(20)), confidence: 0.6), .init(mm: mm(.single(5)), confidence: 0.6)])
        XCTAssertEqual(darts.map(\.segment), [.triple(20), .single(5)])
    }

    // MARK: Confirmation

    func testPersistentLowConfidenceDartIsConfirmedOnce() {
        lock()
        let dart = Scene.Dart(mm: mm(.triple(20)), confidence: 0.12)
        run(4, darts: [dart])
        run(1, darts: [.init(mm: dart.mm, confidence: 0.32)])
        XCTAssertTrue(darts.isEmpty, "five faint frames are not enough evidence yet")
        run(10, darts: [dart])
        XCTAssertEqual(darts.map(\.segment), [.triple(20)])
        run(40, darts: [dart])
        XCTAssertEqual(darts.count, 1, "a dart is reported once")
    }

    /// Phone reports: detections that never reach 0.3 were nearly always barrel points or phantoms.
    func testADetectionThatStaysFaintNeverConfirms() {
        lock()
        run(60, darts: [.init(mm: mm(.single(17)), confidence: 0.2)])
        XCTAssertTrue(darts.isEmpty)
    }

    func testStrongDartIsConfirmedWithinAFewFrames() {
        lock()
        run(DetectorTuning.confirmMinHits, darts: [.init(mm: mm(.double(16)), confidence: 0.6)])
        XCTAssertEqual(darts.map(\.segment), [.double(16)])
    }

    func testFlickerIsNotConfirmed() {
        lock()
        // A false detection at 0.3 in one frame out of four, and one strong single frame elsewhere.
        for i in 0..<40 {
            var d: [Scene.Dart] = i % 4 == 0 ? [.init(mm: mm(.single(7)), confidence: 0.3)] : []
            if i == 20 { d.append(.init(mm: mm(.single(13)), confidence: 0.95)) }
            run(1, darts: d)
        }
        XCTAssertTrue(darts.isEmpty)
    }

    func testTipIsTheMedianOfObservations() throws {
        lock()
        let truth = mm(.triple(19), angle: 0.3)
        scene.noisePixels = 2.5
        run(1, darts: [.init(mm: truth + SIMD2(5, -5), confidence: 0.5)])   // one wild observation
        run(5, darts: [.init(mm: truth, confidence: 0.5)])
        let dart = try XCTUnwrap(darts.first)
        let tip = try XCTUnwrap(dart.boardPosition).millimetres
        XCTAssertLessThan(simd_distance(tip, truth), 2.0)
        XCTAssertEqual(dart.segment, .triple(19))
    }

    func testTipNearAWireWaitsForMoreFrames() {
        lock()
        scene.noisePixels = 0
        let onWire = SIMD2(0, -160.5)   // 0.5 mm outside the inner double wire, in the 20
        run(DetectorTuning.confirmMinHits + 1, darts: [.init(mm: onWire, confidence: 0.9)])
        XCTAssertTrue(darts.isEmpty)
        run(DetectorTuning.wireExtraHits, darts: [.init(mm: onWire, confidence: 0.9)])
        XCTAssertEqual(darts.map(\.segment), [.double(20)])
    }

    func testDetectionNextToAReportedDartIsNotANewDart() {
        lock()
        let first = mm(.triple(20))
        run(4, darts: [.init(mm: first, confidence: 0.8)])
        run(20, darts: [.init(mm: first, confidence: 0.8), .init(mm: first + SIMD2(6, 2), confidence: 0.45)])
        XCTAssertEqual(darts.count, 1)
    }

    func testAtMostThreeDartsPerVisit() {
        lock()
        let four: [Scene.Dart] = [.single(1), .single(2), .single(3), .single(4)].map { .init(mm: mm($0), confidence: 0.7) }
        for n in 1...4 { run(20, darts: Array(four.prefix(n))) }   // thrown one after another
        XCTAssertEqual(darts.count, 3)
        XCTAssertEqual(tracker.tracks.count, 1, "the fourth dart stays a candidate")
    }

    /// Darts that appear together because a player stood in front of the board while they landed
    /// all count: the camera did not see them arrive one by one.
    func testDartsUncoveredTogetherAllCount() {
        lock()
        let three: [Scene.Dart] = [mm(.triple(20)), mm(.single(20)), mm(.single(1))].map { .init(mm: $0, confidence: 0.75) }
        run(5, calibration: Set(0..<5))   // most of the board hidden
        run(20, darts: three)
        XCTAssertEqual(darts.count, 3)
    }

    func testDartsAlreadyInTheBoardAtStartAreIgnored() {
        tracker = MultiFrameTracker(ignoresDartsAtStart: true)
        let old = Scene.Dart(mm: mm(.single(11)), confidence: 0.8)
        run(DetectorTuning.lockFramesNeeded + 20, darts: [old])
        XCTAssertTrue(darts.isEmpty)
        run(6, darts: [old, .init(mm: mm(.triple(20)), confidence: 0.8)])
        XCTAssertEqual(darts.map(\.segment), [.triple(20)])
    }

    // MARK: Misses and short visits

    /// From a steep angle the model also fires along a dart's barrel and flight, which can reach
    /// past the double ring. Such points, and darts in the number ring, are never reported: a miss
    /// scores nothing, and the visit's empty slots become misses when its darts are pulled.
    func testDetectionsOutsideTheScoringAreaAreNeverReported() {
        lock()
        let pastTheDouble = Scene.Dart(mm: SIMD2(15, -176), confidence: 0.6)    // 176.6 mm from the centre
        let numberRing = Scene.Dart(mm: SIMD2(-120, 150), confidence: 0.8)     // 192 mm
        run(40, darts: [pastTheDouble, numberRing])
        XCTAssertTrue(darts.isEmpty)
        run(5, darts: [pastTheDouble, numberRing, .init(mm: mm(.double(20)), confidence: 0.8)])
        XCTAssertEqual(darts.map(\.segment), [.double(20)])
    }

    /// Re-check: a tip that wobbles across the outer double wire is one dart, not two half tracks.
    func testATipWobblingAcrossTheOuterWireConfirms() {
        lock()
        let d20 = mm(.double(20)), direction = d20 / simd_length(d20)
        for i in 0..<40 { run(1, darts: [.init(mm: direction * (i % 2 == 0 ? 169 : 170.5), confidence: 0.8)]) }
        XCTAssertEqual(darts.count, 1)
    }

    /// Re-check: a false detection that never confirms, or one outside the board, must not keep a
    /// short visit open forever.
    func testAFalseCandidateDoesNotBlockThePullForever() {
        lock()
        run(5, darts: [.init(mm: mm(.single(20)), confidence: 0.8)])
        let flicker = Scene.Dart(mm: mm(.single(6)), confidence: 0.08)   // too weak to ever confirm
        let outside = Scene.Dart(mm: SIMD2(0, -179), confidence: 0.6)
        for i in 0..<120 { run(1, darts: i % 5 == 4 ? [outside] : [flicker, outside]) }
        XCTAssertTrue(events.contains(.visitEnded))
        XCTAssertEqual(darts.count, 1)
    }

    func testPullingTheDartsOfAShortVisitEndsIt() {
        lock()
        run(5, darts: [.init(mm: mm(.triple(20)), confidence: 0.8)])
        run(5, darts: [.init(mm: mm(.triple(20)), confidence: 0.8), .init(mm: mm(.single(5)), confidence: 0.8)])
        XCTAssertEqual(darts.count, 2)
        // The third dart missed the board; the player pulls the two that scored.
        run(DetectorTuning.pullFramesNeeded - 1)
        XCTAssertFalse(events.contains(.visitEnded))
        run(1)
        XCTAssertEqual(Array(events.suffix(2)), [.visitEnded, .boardCleared])
        // The next player's darts score.
        run(5, darts: [.init(mm: mm(.double(16)), confidence: 0.8)])
        XCTAssertEqual(darts.last?.segment, .double(16))
    }

    /// Review: a dart seen below the presence floor is still in the board.
    func testAFaintVisitDartKeepsTheVisitOpen() {
        lock()
        let dart = Scene.Dart(mm: mm(.single(20)), confidence: 0.8)
        run(5, darts: [dart])
        run(40, darts: [.init(mm: dart.mm, confidence: 0.03)])
        XCTAssertFalse(events.contains(.visitEnded))
    }

    /// Review: a dart still building evidence is a dart in the board, not an empty board.
    func testADartStillBeingConfirmedBlocksThePull() {
        lock()
        run(5, darts: [.init(mm: mm(.single(20)), confidence: 0.8)])
        let slow = Scene.Dart(mm: mm(.single(6)), confidence: 0.08)   // needs 13 frames to confirm
        run(6, darts: [slow])
        run(1, darts: [.init(mm: slow.mm, confidence: 0.3)])
        run(23, darts: [slow])
        XCTAssertFalse(events.contains(.visitEnded))
        XCTAssertEqual(darts.map(\.segment), [.single(20), .single(6)])
    }

    /// Review: a track past the double ring must not swallow a real double next to it.
    func testAnOutsideTrackDoesNotAbsorbADouble() {
        lock()
        let d20 = mm(.double(20)), direction = d20 / simd_length(d20)
        for radius in [179.0, 172.9] {   // far past the wire, and just past it (re-check 2)
            tracker = MultiFrameTracker(ignoresDartsAtStart: false)
            events = []
            lock()
            let outside = Scene.Dart(mm: direction * radius, confidence: 0.6)
            run(30, darts: [outside])
            for i in 0..<40 { run(1, darts: i % 2 == 0 ? [outside] : [.init(mm: direction * 168, confidence: 0.8)]) }
            XCTAssertEqual(darts.map(\.segment), [.double(20)], "outside track at \(radius) mm")
        }
    }

    func testAShortVisitStaysOpenWhileItsDartsAreSeen() {
        lock()
        let dart = Scene.Dart(mm: mm(.triple(20)), confidence: 0.8)
        run(5, darts: [dart])
        run(40, darts: [.init(mm: dart.mm, confidence: 0.06)])          // seen faintly
        for i in 0...30 { run(1, darts: i % 2 == 0 ? [dart] : []) }       // seen in every other frame
        run(25, calibration: [0, 4])                                      // a player in front of the board
        run(30, calibration: Set(0..<6))                                  // a player beside it
        XCTAssertFalse(events.contains(.visitEnded))
        XCTAssertEqual(clears, 0)
    }

    // MARK: Occlusion and removal

    func testOccludedFramesNeitherConfirmNorClear() {
        lock()
        let dart = Scene.Dart(mm: mm(.single(20)), confidence: 0.7)
        // A player stands in front: only two calibration points are visible.
        run(20, darts: [dart], calibration: [0, 4])
        XCTAssertTrue(darts.isEmpty, "occluded frames do not confirm darts")
        run(4, darts: [dart])
        XCTAssertEqual(darts.count, 1)
        tracker.endVisit()
        run(25, calibration: [3, 9])
        XCTAssertEqual(clears, 0, "occluded frames do not count as an empty board")
        XCTAssertTrue(tracker.isLocked, "a short occlusion keeps the lock")
        run(DetectorTuning.removalFramesNeeded)
        XCTAssertEqual(clears, 1)
    }

    func testPartlyHiddenBoardDoesNotCountAsEmpty() {
        lock()
        run(4, darts: [.init(mm: mm(.single(20)), confidence: 0.7)])
        tracker.endVisit()
        // Half the calibration points hidden (a player beside the board): usable, but not a clear view.
        run(30, calibration: Set(0..<6))
        XCTAssertEqual(clears, 0)
        run(DetectorTuning.removalFramesNeeded)
        XCTAssertEqual(clears, 1)
    }

    func testRemovalNeedsTheDartsAbsentFromCurrentFrames() {
        lock()
        let a = Scene.Dart(mm: mm(.single(20)), confidence: 0.7), b = Scene.Dart(mm: mm(.triple(1)), confidence: 0.7)
        run(5, darts: [a])   // thrown one after the other
        run(5, darts: [a, b])
        XCTAssertEqual(darts.count, 2)
        tracker.endVisit()
        // One dart still there, seen only faintly: not clear.
        run(40, darts: [.init(mm: b.mm, confidence: 0.06)])
        XCTAssertEqual(clears, 0)
        // Seen in every other frame: still not clear.
        for i in 0...30 { run(1, darts: i % 2 == 0 ? [b] : []) }   // ends on a frame that sees it
        XCTAssertEqual(clears, 0)
        run(DetectorTuning.removalFramesNeeded - 1)
        XCTAssertEqual(clears, 0)
        run(1)
        XCTAssertEqual(clears, 1)
        // After the clear, new darts count again.
        run(5, darts: [.init(mm: mm(.double(3)), confidence: 0.7)])
        XCTAssertEqual(darts.last?.segment, .double(3))
    }

    func testNothingIsReportedWhileWaitingForRemoval() {
        lock()
        run(4, darts: [.init(mm: mm(.single(20)), confidence: 0.7)])
        tracker.endVisit()
        run(20, darts: [.init(mm: mm(.single(20)), confidence: 0.7), .init(mm: mm(.single(6)), confidence: 0.7)])
        XCTAssertEqual(darts.count, 1)
    }

    func testDartLeftInTheBoardAfterAClearIsNotReportedLater() {
        lock()
        let scored = Scene.Dart(mm: mm(.single(20)), confidence: 0.7)
        let unscored = Scene.Dart(mm: mm(.single(17)), confidence: 0.15)   // seen too weakly to confirm
        run(4, darts: [scored, unscored])
        tracker.endVisit()
        run(DetectorTuning.removalFramesNeeded, darts: [unscored])
        XCTAssertEqual(clears, 1)
        run(40, darts: [unscored])
        XCTAssertEqual(darts.count, 1, "a dart that was in the board before the clear is background")
    }

    // MARK: Resume and reset

    func testResumeRestoresTheClosedVisit() {
        lock()
        let a = Scene.Dart(mm: mm(.single(20)), confidence: 0.7), b = Scene.Dart(mm: mm(.triple(5)), confidence: 0.7)
        run(5, darts: [a])   // thrown one after the other
        run(5, darts: [a, b])
        XCTAssertEqual(darts.count, 2)
        tracker.endVisit()
        run(5, darts: [a, b])
        tracker.resumeVisit()
        run(10, darts: [a, b])
        XCTAssertEqual(darts.count, 2, "the reopened visit's darts are not reported again")
        run(5, darts: [a, b, .init(mm: mm(.double(10)), confidence: 0.7)])
        XCTAssertEqual(darts.map(\.segment), [.single(20), .triple(5), .double(10)])
    }

    func testResumeOfAVisitWithoutCameraDartsReportsNewDarts() {
        lock()
        tracker.endVisit()   // the player typed the darts by hand
        run(3)
        tracker.resumeVisit()
        run(5, darts: [.init(mm: mm(.single(12)), confidence: 0.7)])
        XCTAssertEqual(darts.map(\.segment), [.single(12)])
        XCTAssertEqual(tracker.visitDarts.count, 1)
    }

    func testResumeAfterAnotherEndVisitRestoresOnlyTheLastVisit() {
        lock()
        let a = Scene.Dart(mm: mm(.single(20)), confidence: 0.7)
        run(5, darts: [a])
        tracker.endVisit()          // visit 1 closed, dart a still in the board
        tracker.endVisit()          // visit 2 (typed by hand) closed too
        tracker.resumeVisit()       // undo reopens visit 2
        XCTAssertTrue(tracker.visitDarts.isEmpty)
        XCTAssertEqual(tracker.oldDarts.count, 1)
        run(10, darts: [a, .init(mm: mm(.single(1)), confidence: 0.7)])
        XCTAssertEqual(darts.map(\.segment), [.single(20), .single(1)])
    }

    func testRemovalInvalidatesTheSnapshot() {
        lock()
        let a = Scene.Dart(mm: mm(.single(20)), confidence: 0.7)
        run(5, darts: [a])
        tracker.endVisit()
        run(DetectorTuning.removalFramesNeeded)
        XCTAssertEqual(clears, 1)
        tracker.resumeVisit()   // too late: the board was cleared
        XCTAssertTrue(tracker.visitDarts.isEmpty)
        XCTAssertEqual(tracker.phase, .throwing)
    }

    func testResetKeepsABarrierUntilTheBoardIsClear() {
        lock()
        let a = Scene.Dart(mm: mm(.double(20)), confidence: 0.8)
        run(5, darts: [a])
        tracker.reset()
        XCTAssertEqual(tracker.phase, .resetBarrier)
        run(20, darts: [a, .init(mm: mm(.single(3)), confidence: 0.8)])
        XCTAssertEqual(darts.count, 1, "nothing is reported until the board is clear")
        run(DetectorTuning.removalFramesNeeded)
        XCTAssertEqual(clears, 0, "lifting the reset barrier is not a visit's board clear")
        XCTAssertEqual(tracker.phase, .throwing)
        run(5, darts: [.init(mm: mm(.triple(19)), confidence: 0.8)])
        XCTAssertEqual(darts.last?.segment, .triple(19))
    }

    func testResetWithAnEmptyBoardHasNoBarrier() {
        lock()
        tracker.reset()
        XCTAssertEqual(tracker.phase, .throwing)
        run(4, darts: [.init(mm: mm(.single(8)), confidence: 0.8)])
        XCTAssertEqual(darts.map(\.segment), [.single(8)])
    }

    func testResetInvalidatesTheSnapshot() {
        lock()
        run(5, darts: [.init(mm: mm(.single(20)), confidence: 0.7)])
        tracker.endVisit()
        tracker.reset()
        tracker.resumeVisit()
        XCTAssertTrue(tracker.visitDarts.isEmpty)
        XCTAssertEqual(tracker.phase, .resetBarrier)
    }

    // MARK: Review findings (GPT-6.1 Sol review of the RF-DETR detector)

    /// Seeing a closed visit's dart in a partial view starts the removal count over.
    func testOldDartInAPartialViewRestartsTheRemovalCount() {
        lock()
        let a = Scene.Dart(mm: SIMD2(0, -60), confidence: 0.8)
        run(4, darts: [a])
        XCTAssertEqual(tracker.visitDarts.count, 1)
        tracker.endVisit()
        run(DetectorTuning.removalFramesNeeded - 1)
        XCTAssertEqual(clears, 0)
        run(1, darts: [a], calibration: Set(0..<6))
        XCTAssertEqual(tracker.lastFrameUse, .usable(clearView: false))
        run(1)
        XCTAssertEqual(clears, 0, "the dart was just seen: the board is not clear")
        run(DetectorTuning.removalFramesNeeded - 1)
        XCTAssertEqual(clears, 1)
    }

    /// A lock lost to a long occlusion and formed again at the same pose from a partial board
    /// keeps the full board as its clear view.
    func testRelockDuringOcclusionDoesNotTurnAPartialBoardIntoAClearView() {
        lock()
        run(4, darts: [.init(mm: SIMD2(0, -60), confidence: 0.8)])
        tracker.endVisit()
        run(DetectorTuning.lostFramesBeforeUnlock, calibration: [0, 1])
        XCTAssertFalse(tracker.isLocked)
        run(12, calibration: Set(0..<6))
        XCTAssertTrue(tracker.isLocked)
        XCTAssertEqual(tracker.lastFrameUse, .usable(clearView: false))
        XCTAssertEqual(clears, 0, "the dart may still be behind the player")
        run(DetectorTuning.removalFramesNeeded)
        XCTAssertEqual(clears, 1, "the full board seen again clears")
    }

    /// After the camera really moved, the new lock sets its own clear view.
    func testRelockAtANewPoseSetsItsOwnClearView() {
        lock()
        scene.camera = Homography(rows: [1.9, 0.1, 560, -0.1, 1.95, 640, 0.0003, -0.0001, 1])
        run(DetectorTuning.movedFramesNeeded + DetectorTuning.lockFramesNeeded + 2, calibration: Set(0..<8))
        XCTAssertTrue(tracker.isLocked)
        XCTAssertEqual(tracker.lastFrameUse, .usable(clearView: true))
    }

    /// Points thrown off by a hand or a shadow, frame after frame, never move the lock: the rest
    /// of the board fits without them.
    func testAFewMisplacedPointsDoNotMoveTheLock() throws {
        lock()
        let before = try XCTUnwrap(tracker.homography)
        let camera = scene.camera
        // Three neighbouring points (27°-81°) seen 10 mm off, next to nine true ones.
        scene.camera = Homography(rows: [1, 0, 0, 0, 1, 10, 0, 0, 1]).then(camera)
        let misplaced = scene.frame(calibration: [3, 4, 5])
        scene.camera = camera
        for _ in 0..<30 {
            var frame = scene.frame(calibration: Set(0..<12).subtracting([3, 4, 5]))
            frame.detections += misplaced.detections
            events += tracker.process(frame)
        }
        let after = try XCTUnwrap(tracker.homography)
        for target in BoardCalibration.targetsMM {
            let pixel = camera.apply(target)!
            XCTAssertLessThan(simd_distance(after.apply(pixel)!, before.apply(pixel)!), 1)
        }
    }

    /// An unconfirmed dart at reset is still a dart that may be in the board.
    func testResetWithAnUnconfirmedDartKeepsTheBarrier() {
        lock()
        let old = Scene.Dart(mm: SIMD2(0, -60), confidence: 0.8)
        run(1, darts: [old])
        XCTAssertEqual(tracker.tracks.count, 1)
        XCTAssertTrue(tracker.visitDarts.isEmpty)
        tracker.reset()
        XCTAssertEqual(tracker.phase, .resetBarrier)
        run(5, darts: [old, .init(mm: SIMD2(60, 0), confidence: 0.8)])
        XCTAssertTrue(darts.isEmpty)
    }

    /// A dart next to one pulled moments ago is held back for `removedMemoryFrames`, then scores.
    func testNewDartWhereThePreviousVisitsDartWasScoresAfterTheRemovalMemory() {
        lock()
        let a = SIMD2(0.0, -60.0)
        run(4, darts: [.init(mm: a, confidence: 0.8)])
        XCTAssertEqual(tracker.visitDarts.count, 1)
        tracker.endVisit()
        run(DetectorTuning.removalFramesNeeded)
        XCTAssertEqual(clears, 1)
        let before = darts.count
        let again = Scene.Dart(mm: a + SIMD2(1, 0), confidence: 0.8)
        run(DetectorTuning.removedMemoryFrames - 1, darts: [again])
        XCTAssertEqual(darts.count, before, "maybe the old dart, hidden by a hand during the clear")
        run(50 - DetectorTuning.removedMemoryFrames + 1, darts: [again])
        XCTAssertEqual(darts.count, before + 1, "a new dart in the same bed must score")
    }

    // MARK: One landing, one dart

    /// Locks and keeps a clear view long enough that new darts count as seen arriving.
    private func lockAndWatch() {
        lock()
        run(DetectorTuning.arrivalClearFrames)
    }

    /// `p` moved `millimetres` away from the board centre (along a barrel seen from the side).
    private func outward(_ p: SIMD2<Double>, _ millimetres: Double) -> SIMD2<Double> {
        p + simd_normalize(p) * millimetres
    }

    /// The model also fires along the barrel of a dart that just landed. A barrel point that
    /// appears with the tip and lasts is part of that dart (phone reports, 2026-11-13).
    func testBarrelPointThatAppearsWithADartIsPartOfIt() {
        lockAndWatch()
        let tip = mm(.single(18), angle: -0.2)
        run(20, darts: [.init(mm: tip, confidence: 0.75), .init(mm: outward(tip, 30), confidence: 0.3)])
        XCTAssertEqual(darts.map(\.segment), [.single(18)])
    }

    /// The same when the barrel point is the stronger detection: still one dart, not two.
    func testStrongerBarrelPointStillMakesOneDart() {
        lockAndWatch()
        let tip = mm(.single(2))
        run(20, darts: [.init(mm: tip, confidence: 0.2), .init(mm: outward(tip, 20), confidence: 0.6)])
        XCTAssertEqual(darts.count, 1)
    }

    /// A second dart landing next to the first a couple of seconds later still counts.
    func testADartLandingNextToAnotherLaterCounts() {
        lockAndWatch()
        let first = mm(.triple(20), angle: -0.2)
        let second = first + SIMD2(14, 2)
        run(25, darts: [.init(mm: first, confidence: 0.8)])
        run(20, darts: [.init(mm: first, confidence: 0.8), .init(mm: second, confidence: 0.75)])
        XCTAssertEqual(darts.count, 2)
    }

    /// A barrel point that flickers away and back later still belongs to its dart.
    func testFlickeringBarrelPointDoesNotComeBackAsADart() {
        lockAndWatch()
        let tip = mm(.single(2), angle: 0.1)
        let barrel = outward(tip, 15)
        run(12, darts: [.init(mm: tip, confidence: 0.7), .init(mm: barrel, confidence: 0.2)])
        run(15, darts: [.init(mm: tip, confidence: 0.7)])                                   // forgotten as a track
        run(30, darts: [.init(mm: tip, confidence: 0.7), .init(mm: barrel, confidence: 0.2)])   // and back
        XCTAssertEqual(darts.count, 1)
    }

    /// A strong detection on a barrel point is a new dart landing there.
    func testNewDartOnABarrelPointCounts() {
        lockAndWatch()
        let tip = mm(.single(20), angle: -0.1)
        let barrel = outward(tip, 18)
        run(12, darts: [.init(mm: tip, confidence: 0.75), .init(mm: barrel, confidence: 0.2)])
        run(25, darts: [.init(mm: tip, confidence: 0.75)])
        run(20, darts: [.init(mm: tip, confidence: 0.75), .init(mm: barrel, confidence: 0.8)])
        XCTAssertEqual(darts.count, 2)
    }

    /// Darts held in the hand during a pull: the model detects their points all over the frame,
    /// and one of them can last long enough to confirm (phone, 2026-11-19: a "T5" at 0.55 from 27
    /// detections). A candidate that starts in such cluttered frames never scores, and a dart
    /// thrown after them counts.
    func testDartsInTheHandDuringAPullNeverScore() {
        lockAndWatch()
        let first = mm(.single(20))
        run(25, darts: [.init(mm: first, confidence: 0.8)])
        XCTAssertEqual(darts.count, 1)
        let held = mm(.triple(5))
        var clutter: [Scene.Dart] = [.init(mm: held, confidence: 0.55)]
        for i in 0..<11 { clutter.append(.init(mm: SIMD2(-120 + 22 * Double(i), 40 + 3 * Double(i % 4)), confidence: 0.12)) }
        run(2, darts: Array(clutter.dropFirst()))   // the hand arrives
        run(8, darts: clutter)                       // one point of the darts it holds grows strong
        // Fewer detections, still more than a board holds: still cluttered.
        run(4, darts: Array(clutter.prefix(9)))
        XCTAssertEqual(darts.count, 1)
        run(30)   // the board is clear again: the darts were pulled
        XCTAssertTrue(events.contains(.visitEnded))
        XCTAssertEqual(clears, 1)
        let next = mm(.single(1), angle: 0.2)
        run(25, darts: [.init(mm: next, confidence: 0.8)])
        XCTAssertEqual(darts.map(\.segment), [.single(20), .single(1)])
    }

    /// A faint candidate from before a clutter (a pull) is dropped, not resumed with its old first
    /// frame: a dart landing there later, with a point on its flight, is still one dart.
    func testACandidateFromBeforeAClutterDoesNotSplitTheNextLanding() {
        lockAndWatch()
        let tip = mm(.single(20)), flight = outward(mm(.single(20)), 50)
        let clutter = (0..<12).map { Scene.Dart(mm: SIMD2(-130 + 22 * Double($0), 120), confidence: 0.12) }
        run(1, darts: [.init(mm: tip, confidence: 0.1)])
        run(6, darts: clutter)
        run(DetectorTuning.arrivalClearFrames)
        run(25, darts: [.init(mm: tip, confidence: 0.8), .init(mm: flight, confidence: 0.4)])
        XCTAssertEqual(darts.map(\.segment), [.single(20)])
    }

    /// A hand point that appears on the very first busy frame is the hand's too, once the next
    /// frame shows the clutter goes on.
    func testAHandPointFromTheFirstBusyFrameNeverScores() {
        lockAndWatch()
        let first = mm(.single(20))
        run(25, darts: [.init(mm: first, confidence: 0.8)])
        let noise = (0..<11).map { Scene.Dart(mm: SIMD2(-120 + 22 * Double($0), 40 + 3 * Double($0 % 4)), confidence: 0.12) }
        run(4, darts: [.init(mm: first, confidence: 0.8), .init(mm: mm(.triple(5)), confidence: 0.55)] + noise)
        XCTAssertEqual(darts.count, 1)
    }

    /// The hand leaves; a real dart landing right where one of its points was still scores.
    func testADartLandingWhereAHandPointWasScores() {
        lockAndWatch()
        let spot = mm(.single(12))
        let noise = (0..<11).map { Scene.Dart(mm: SIMD2(-120 + 22 * Double($0), 40 + 3 * Double($0 % 4)), confidence: 0.12) }
        run(2, darts: noise)
        run(3, darts: [.init(mm: spot, confidence: 0.3)] + noise)
        run(1)
        run(20, darts: [.init(mm: spot + SIMD2(3, 2), confidence: 0.8)])
        XCTAssertEqual(darts.map(\.segment), [.single(12)])
    }

    /// A dart landing can burst into many detections in its landing frame alone (2026-11-13): one
    /// busy frame is not a hand, and the dart scores.
    func testADartLandingInABusyFrameScores() {
        lockAndWatch()
        let a = mm(.single(17))
        let burst = (0..<10).map { Scene.Dart(mm: SIMD2(-130 + 22 * Double($0), 120), confidence: 0.1) }
        run(1, darts: [.init(mm: a, confidence: 0.52)] + burst)
        run(20, darts: [.init(mm: a, confidence: 0.78)])
        XCTAssertEqual(darts.map(\.segment), [.single(17)])
    }

    /// A dart hidden behind another, seen only faintly, shows itself as the player's hand moves the
    /// front dart (phone, 2026-11-18): it was tracked before the clutter, so it still scores.
    func testAHiddenDartRevealedDuringClutterStillScores() {
        lockAndWatch()
        let a = mm(.single(5)), b = mm(.single(12))
        run(25, darts: [.init(mm: a, confidence: 0.8)])
        run(25, darts: [.init(mm: a, confidence: 0.8), .init(mm: b, confidence: 0.15)])
        XCTAssertEqual(darts.count, 1)
        let clutter = (0..<12).map { Scene.Dart(mm: SIMD2(-130 + 22 * Double($0), 120), confidence: 0.12) }
        run(3, darts: [.init(mm: a, confidence: 0.8), .init(mm: b, confidence: 0.15)] + clutter)   // the hand arrives
        run(6, darts: [.init(mm: a, confidence: 0.8), .init(mm: b, confidence: 0.78)] + clutter)
        XCTAssertEqual(darts.count, 2)
    }

    /// A cluttered frame that still shows a dart of the closed visit starts its removal count over.
    func testAClutteredFrameShowingAnOldDartRestartsItsRemoval() {
        lockAndWatch()
        let a = Scene.Dart(mm: mm(.single(20)), confidence: 0.7)
        run(10, darts: [a])
        tracker.endVisit()
        run(DetectorTuning.removalFramesNeeded - 1)
        let clutter = (0..<12).map { Scene.Dart(mm: SIMD2(-130 + 22 * Double($0), 120), confidence: 0.12) }
        run(3, darts: [a] + clutter)
        run(DetectorTuning.removalFramesNeeded - 1)
        XCTAssertEqual(clears, 0)
        run(1)
        XCTAssertEqual(clears, 1)
    }

    /// A barrel point of a dart that landed after the first must not hide that new dart's tip.
    func testBarrelOfTheSecondDartDoesNotCount() {
        lockAndWatch()
        let first = mm(.single(5))
        let second = mm(.single(1), angle: 0.2)
        run(25, darts: [.init(mm: first, confidence: 0.8)])
        run(20, darts: [.init(mm: first, confidence: 0.8), .init(mm: second, confidence: 0.75),
                        .init(mm: outward(second, 25), confidence: 0.3)])
        XCTAssertEqual(darts.map(\.segment), [.single(5), .single(1)])
    }

    /// Review: darts uncovered over two frames while the view recovers all count.
    func testDartsUncoveredOneFrameApartAllCount() {
        lockAndWatch()
        let a = mm(.single(20)), b = mm(.triple(1), angle: 0.1), c = outward(b, 30)
        run(5, calibration: Set(0..<5))   // a player in front of the board
        run(1, darts: [.init(mm: a, confidence: 0.8)])
        run(20, darts: [.init(mm: a, confidence: 0.8), .init(mm: b, confidence: 0.8), .init(mm: c, confidence: 0.4)])
        XCTAssertEqual(darts.count, 3)
    }

    /// Review: a new dart on a remembered barrel point that is seen strongly as it lands, then
    /// faintly, still counts.
    func testNewDartOnABarrelPointThatTurnsFaintCounts() {
        lockAndWatch()
        let tip = mm(.single(20), angle: -0.1)
        let barrel = outward(tip, 18)
        run(12, darts: [.init(mm: tip, confidence: 0.75), .init(mm: barrel, confidence: 0.2)])
        run(25, darts: [.init(mm: tip, confidence: 0.75)])
        run(2, darts: [.init(mm: tip, confidence: 0.75), .init(mm: barrel, confidence: 0.8)])
        run(20, darts: [.init(mm: tip, confidence: 0.75), .init(mm: barrel, confidence: 0.2)])
        XCTAssertEqual(darts.count, 2)
    }

    /// A barrel point that creeps up with lone spikes over 0.5 (phone report) stays a barrel.
    func testBarrelPointWithLoneSpikesStaysABarrel() {
        lockAndWatch()
        let tip = mm(.single(18), angle: 0.1), barrel = outward(tip, 35)
        run(10, darts: [.init(mm: tip, confidence: 0.75), .init(mm: barrel, confidence: 0.2)])
        for i in 0..<60 {
            run(1, darts: [.init(mm: tip, confidence: 0.75), .init(mm: barrel, confidence: i % 7 == 6 ? 0.56 : 0.35)])
        }
        XCTAssertEqual(darts.count, 1)
    }

    /// Review: a barrel point confirming after the visit was reopened stays that dart's barrel.
    func testBarrelPointOfAResumedVisitIsRemembered() {
        lockAndWatch()
        let tip = mm(.single(3)), barrel = outward(tip, 20)
        run(3, darts: [.init(mm: tip, confidence: 0.8)])
        XCTAssertEqual(darts.count, 1)
        tracker.endVisit()
        run(1, darts: [.init(mm: tip, confidence: 0.8), .init(mm: barrel, confidence: 0.35)])
        tracker.resumeVisit()
        run(10, darts: [.init(mm: tip, confidence: 0.8), .init(mm: barrel, confidence: 0.35)])
        run(15, darts: [.init(mm: tip, confidence: 0.8)])
        run(30, darts: [.init(mm: tip, confidence: 0.8), .init(mm: barrel, confidence: 0.35)])
        XCTAssertEqual(darts.count, 1)
    }

    /// Review: a faint detection left on a barrel point does not keep a pulled visit open or the
    /// board from clearing.
    func testBarrelPointDoesNotBlockThePullOrTheClear() {
        lockAndWatch()
        let tip = mm(.single(11)), barrel = outward(tip, 25)
        run(10, darts: [.init(mm: tip, confidence: 0.8), .init(mm: barrel, confidence: 0.3)])
        XCTAssertEqual(darts.count, 1)
        run(DetectorTuning.pullFramesNeeded + 2, darts: [.init(mm: barrel, confidence: 0.06)])
        XCTAssertTrue(events.contains(.visitEnded), "the short visit's dart was pulled")

        // The next visit: a dart elsewhere, closed with Next, then pulled.
        events = []
        let tip2 = mm(.single(14), angle: 0.2), barrel2 = outward(tip2, 25)
        run(10, darts: [.init(mm: tip2, confidence: 0.8), .init(mm: barrel2, confidence: 0.3)])
        XCTAssertEqual(darts.count, 1)
        tracker.endVisit()
        run(DetectorTuning.removalFramesNeeded + 2, darts: [.init(mm: barrel2, confidence: 0.06)])
        XCTAssertTrue(events.contains(.boardCleared))
    }

    // MARK: Stacked darts (phone reports, 2026-11-15)

    /// A dart that lands 7-9 mm from one already reported, seconds later, and stays strong is a
    /// second dart. The model saw such darts at 0.6-0.85; they used to be absorbed by the first.
    func testADartStackedNextToAnotherLaterCounts() {
        lockAndWatch()
        let first = mm(.triple(20))
        let second = first + SIMD2(7, 3)
        run(25, darts: [.init(mm: first, confidence: 0.8)])
        run(20, darts: [.init(mm: first, confidence: 0.8), .init(mm: second, confidence: 0.75)])
        XCTAssertEqual(darts.count, 2)
        if darts.count == 2, let position = darts[1].boardPosition {
            XCTAssertLessThan(simd_distance(position.millimetres, second), 1)
        }
    }

    /// A duplicate the model makes of one dart (22-51-58: a D1 on the wire) appears with it,
    /// wanders and flickers: never a second dart, even when it spikes over 0.5.
    func testAFlickeringDuplicateBesideADartIsNotASecondDart() {
        lockAndWatch()
        let tip = mm(.double(1), angle: 0.1)
        let confidences = [0.06, 0.3, 0.55, 0.2, 0.52, 0.1, 0.4, 0.55, 0.35, 0.51]
        for i in 0..<80 {
            let wander = SIMD2(5 + Double(i % 5), Double(i % 3) - 1)
            run(1, darts: [.init(mm: tip, confidence: 0.8), .init(mm: tip + wander, confidence: confidences[i % confidences.count])])
        }
        XCTAssertEqual(darts.count, 1)
    }

    /// Review S1: a duplicate that wanders from just inside the radius to just outside it is still
    /// beside the dart, and needs the stacked-dart evidence.
    func testADuplicateWanderingPastTheRadiusIsNotASecondDart() {
        lockAndWatch()
        let tip = mm(.single(20), angle: 0.1)
        run(25, darts: [.init(mm: tip, confidence: 0.8)])
        run(2, darts: [.init(mm: tip, confidence: 0.8), .init(mm: tip + SIMD2(0, 9.9), confidence: 0.55)])
        run(2, darts: [.init(mm: tip, confidence: 0.8), .init(mm: tip + SIMD2(0, 10.2), confidence: 0.55)])
        run(10, darts: [.init(mm: tip, confidence: 0.8)])
        XCTAssertEqual(darts.count, 1)
    }

    /// Review S1, round 2: the same after so long outside the radius that the observations inside
    /// it were dropped from the track (`tipObservationsKept`).
    func testADuplicateLongPastTheRadiusIsNotASecondDart() {
        lockAndWatch()
        let tip = mm(.single(20), angle: 0.1)
        run(25, darts: [.init(mm: tip, confidence: 0.8)])
        run(1, darts: [.init(mm: tip, confidence: 0.8), .init(mm: tip + SIMD2(0, 9.9), confidence: 0.55)])
        for i in 0..<(2 * DetectorTuning.tipObservationsKept) {
            run(1, darts: [.init(mm: tip, confidence: 0.8), .init(mm: tip + SIMD2(0, 10.2), confidence: i % 2 == 0 ? 0.55 : 0.3)])
        }
        XCTAssertEqual(darts.count, 1)
    }

    /// Review S1, round 3: a duplicate whose track expired (its faint detections inside the radius
    /// belong to the dart) and starts again just outside the radius is still beside the dart.
    func testADuplicateWhoseTrackRestartsPastTheRadiusIsNotASecondDart() {
        lockAndWatch()
        let tip = mm(.single(20), angle: 0.1)
        run(25, darts: [.init(mm: tip, confidence: 0.8)])
        run(1, darts: [.init(mm: tip, confidence: 0.8), .init(mm: tip + SIMD2(0, 9.9), confidence: 0.55)])
        run(DetectorTuning.maxMissStreak + 1, darts: [.init(mm: tip, confidence: 0.8), .init(mm: tip + SIMD2(0, 9.9), confidence: 0.3)])
        for i in 0..<60 {
            run(1, darts: [.init(mm: tip, confidence: 0.8), .init(mm: tip + SIMD2(0, 10.2), confidence: i % 2 == 0 ? 0.55 : 0.3)])
        }
        XCTAssertEqual(darts.count, 1)
    }

    /// Review, round 4: past the 10 mm radius a steady weaker second dart still counts, and so
    /// does one that hides the first dart's tip.
    func testASteadyDartJustPastTheRadiusCounts() {
        lockAndWatch()
        let first = mm(.single(20), angle: -0.2)
        run(25, darts: [.init(mm: first, confidence: 0.8)])
        run(25, darts: [.init(mm: first, confidence: 0.8), .init(mm: first + SIMD2(11.5, 0), confidence: 0.45)])
        XCTAssertEqual(darts.count, 2)
    }

    func testADartHidingTheFirstOnesTipJustPastTheRadiusCounts() {
        lockAndWatch()
        let first = mm(.single(20), angle: -0.2)
        run(25, darts: [.init(mm: first, confidence: 0.8)])
        run(25, darts: [.init(mm: first + SIMD2(11.5, 0), confidence: 0.8)])
        XCTAssertEqual(darts.count, 2)
    }

    /// A strong point beside a dart that was there from the moment the dart landed is part of it.
    func testAStrongPointThatAppearedWithItsDartIsNotASecondDart() {
        lockAndWatch()
        let tip = mm(.single(5))
        run(60, darts: [.init(mm: tip, confidence: 0.8), .init(mm: tip + SIMD2(6, -5), confidence: 0.7)])
        XCTAssertEqual(darts.count, 1)
    }

    /// A strong point beside a dart whose own tip is no longer seen is that dart, moved or seen
    /// differently: not a second dart.
    func testAPointBesideADartThatIsNoLongerSeenIsNotASecondDart() {
        lockAndWatch()
        let tip = mm(.single(13))
        run(25, darts: [.init(mm: tip, confidence: 0.8)])
        run(40, darts: [.init(mm: tip + SIMD2(7, 2), confidence: 0.8)])
        XCTAssertEqual(darts.count, 1)
    }

    // MARK: Phone session, 2026-11-16

    /// The first dart's detection sat 3 mm off once a second dart landed 8 mm away (16-05-00):
    /// the second dart still counts at once rather than seconds later.
    func testAStackedDartCountsWhileTheFirstOnesTipIsSeenSlightlyOff() {
        lockAndWatch()
        let first = mm(.single(12)), second = first + SIMD2(8, 2)
        run(25, darts: [.init(mm: first, confidence: 0.7)])
        run(8, darts: [.init(mm: first + SIMD2(0, -3), confidence: 0.3), .init(mm: second, confidence: 0.71)])
        XCTAssertEqual(darts.count, 2)
    }

    /// A barrel point that landed with its dart and then held at 0.35-0.6 for seconds is still
    /// that dart (16-06-08: 42 mm up a steep 18, it scored as a second dart).
    func testABarrelPointThatTurnsStrongLaterIsStillPartOfItsDart() {
        lockAndWatch()
        let tip = mm(.single(18), angle: -0.1), barrel = outward(tip, 40)
        run(3, darts: [.init(mm: tip, confidence: 0.6), .init(mm: barrel, confidence: 0.3)])
        XCTAssertEqual(darts.count, 1)
        let levels = [0.39, 0.54, 0.5, 0.51, 0.46, 0.6, 0.56, 0.33, 0.45, 0.53]
        for i in 0..<80 {
            run(1, darts: [.init(mm: tip, confidence: 0.3), .init(mm: barrel, confidence: levels[i % levels.count])])
        }
        XCTAssertEqual(darts.count, 1)
    }

    /// The same after the game closed the visit (the dart read as a bust) and a correction
    /// reopened it.
    func testABarrelPointThatTurnsStrongWhileTheVisitIsClosedIsStillPartOfItsDart() {
        lockAndWatch()
        let tip = mm(.single(18), angle: -0.1), barrel = outward(tip, 40)
        run(3, darts: [.init(mm: tip, confidence: 0.6), .init(mm: barrel, confidence: 0.3)])
        tracker.endVisit()
        let levels = [0.39, 0.54, 0.5, 0.51, 0.46, 0.6, 0.56, 0.33, 0.45, 0.53]
        for i in 0..<30 {
            run(1, darts: [.init(mm: tip, confidence: 0.3), .init(mm: barrel, confidence: levels[i % levels.count])])
        }
        tracker.resumeVisit()
        for i in 0..<60 {
            run(1, darts: [.init(mm: tip, confidence: 0.3), .init(mm: barrel, confidence: levels[i % levels.count])])
        }
        XCTAssertEqual(darts.count, 1)
    }

    /// Review: each barrel point keeps its own recency. Seeing one barrel point does not make a
    /// long-unseen second one a barrel still in view: a real dart landing there scores.
    func testANewDartOnAnUnseenBarrelPointCountsWhileAnotherIsSeen() {
        lockAndWatch()
        let tip = SIMD2<Double>(0, -40), near = SIMD2<Double>(0, -70), far = SIMD2<Double>(0, -100)
        run(3, darts: [.init(mm: tip, confidence: 0.8), .init(mm: near, confidence: 0.2), .init(mm: far, confidence: 0.2)])
        XCTAssertEqual(darts.count, 1)
        run(25, darts: [.init(mm: tip, confidence: 0.8), .init(mm: near, confidence: 0.2)])
        run(20, darts: [.init(mm: tip, confidence: 0.8), .init(mm: near, confidence: 0.2), .init(mm: far, confidence: 0.8)])
        XCTAssertEqual(darts.map(\.segment), [.single(20), .triple(20)])
    }

    // MARK: Walking up without darts

    /// The player is at the board: two calibration points visible.
    private func walkUp(frames: Int = 15) { run(frames, calibration: [0, 4]) }

    /// The player walking up with darts in hand: the hidden board still counts as hidden.
    func testAClutteredWalkUpStillEndsAnEmptyVisit() {
        lock()
        run(DetectorTuning.walkUpClearFrames)
        let clutter = (0..<12).map { Scene.Dart(mm: SIMD2(-130 + 22 * Double($0), 120), confidence: 0.12) }
        run(15, darts: clutter, calibration: [0, 4])
        run(DetectorTuning.pullFramesNeeded)
        XCTAssertEqual(events.filter { $0 == .emptyVisitEnded }.count, 1)
    }

    /// Three darts that all missed: nothing was reported, and the player walks up to the board
    /// and back. The visit ends empty once the board is clear again, and the next dart starts
    /// a new visit.
    func testWalkingUpAfterThreeMissesEndsTheVisit() {
        lock()
        run(DetectorTuning.walkUpClearFrames)
        walkUp()
        run(DetectorTuning.pullFramesNeeded - 1)
        XCTAssertFalse(events.contains(.emptyVisitEnded))
        run(1)
        XCTAssertEqual(events.filter { $0 == .emptyVisitEnded }.count, 1)
        // Walking back to the line hides the board again: not another empty visit.
        walkUp()
        run(DetectorTuning.walkUpClearFrames - 10)
        run(5, darts: [.init(mm: mm(.single(20)), confidence: 0.8)])
        XCTAssertEqual(darts.map(\.segment), [.single(20)])
        XCTAssertEqual(events.filter { $0 == .emptyVisitEnded }.count, 1)
    }

    /// Hiding the board soon after the visit opened (walking back after the clear) is no walk-up,
    /// nor is a brief pass; a walk-up later in the same visit still counts.
    func testHidingTheBoardEarlyOrBrieflyDoesNotEndTheVisit() {
        lock()
        run(10)
        walkUp()
        run(40)
        run(DetectorTuning.walkUpHiddenFrames - 1, calibration: [0, 4])
        run(30)
        XCTAssertFalse(events.contains(.emptyVisitEnded))
        walkUp()
        run(DetectorTuning.pullFramesNeeded)
        XCTAssertTrue(events.contains(.emptyVisitEnded))
    }

    /// Review: two brief passes a second apart are not one walk-up.
    func testTwoBriefPassesAreNotAWalkUp() {
        lock()
        run(60)
        run(DetectorTuning.walkUpHiddenFrames - 1, calibration: [0, 4])
        run(11)
        run(1, calibration: [0, 4])
        run(DetectorTuning.pullFramesNeeded)
        XCTAssertFalse(events.contains(.emptyVisitEnded))
    }

    /// A walk-up the camera glimpses the board through for a frame or two is still one walk-up.
    func testAWalkUpWithAGlimpseOfTheBoardCounts() {
        lock()
        run(60)
        run(4, calibration: [0, 4])
        run(2)
        run(4, calibration: [0, 4])
        run(DetectorTuning.pullFramesNeeded)
        XCTAssertTrue(events.contains(.emptyVisitEnded))
    }

    /// Someone beside the board (part of it hidden) is not a walk-up.
    func testAPartlyHiddenBoardIsNotAWalkUp() {
        lock()
        run(60)
        run(30, calibration: Set(0..<6))
        run(30)
        XCTAssertFalse(events.contains(.emptyVisitEnded))
    }

    /// A dart the camera sees but has not reported (too faint) may be what the player fetches:
    /// the visit stays open, as before.
    func testAFaintUnreportedDartKeepsAnEmptyVisitOpen() {
        lock()
        let faint = Scene.Dart(mm: mm(.single(7)), confidence: 0.12)   // never reaches the 0.3 peak
        run(60, darts: [faint])
        walkUp()
        run(30)
        XCTAssertFalse(events.contains(.emptyVisitEnded))
        XCTAssertTrue(darts.isEmpty)
    }

    /// Someone walked past and the player throws as the board clears: the dart scores in this visit.
    func testADartLandingAsTheBoardClearsKeepsTheVisit() {
        lock()
        run(60)
        walkUp()
        run(2)
        let dart = Scene.Dart(mm: mm(.single(7)), confidence: 0.1)
        run(12, darts: [dart])
        run(1, darts: [.init(mm: dart.mm, confidence: 0.35)])
        run(10, darts: [dart])
        XCTAssertFalse(events.contains(.emptyVisitEnded))
        XCTAssertEqual(darts.map(\.segment), [.single(7)])
    }

    /// A visit with a dart reported ends by the pull, never as an empty visit.
    func testAVisitWithADartIsNotEndedAsEmpty() {
        lock()
        run(60)
        run(5, darts: [.init(mm: mm(.single(20)), confidence: 0.8)])
        walkUp()
        run(30)
        XCTAssertFalse(events.contains(.emptyVisitEnded))
        XCTAssertTrue(events.contains(.visitEnded))
    }
}
