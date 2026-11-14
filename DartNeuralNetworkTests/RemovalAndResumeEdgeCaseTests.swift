// Edge cases found by the second independent review (GPT-6.1 Sol, 2026-11-08): removal finishing on a
// partial re-lock, a dart first seen on the clearing frame, darts dropped by the game exhausting a
// reopened visit, and event filtering across reset and resume.
import XCTest
import simd
@testable import DartNeuralNetwork

private struct EdgeScene {
    var camera = HomographyTests.camera
    func frame(_ darts: [SIMD2<Double>] = [], calibration: Set<Int> = Set(0..<12)) -> FrameObservation {
        var ds = calibration.sorted().map { ModelDetection(classIndex: $0, point: camera.apply(BoardCalibration.targetsMM[$0])!, confidence: 0.9) }
        ds += darts.map { ModelDetection(classIndex: 12, point: camera.apply($0)!, confidence: 0.8) }
        return FrameObservation(imageSize: CGSize(width: 1080, height: 1440), detections: ds)
    }
}

final class RemovalEdgeCaseTests: XCTestCase {
    func testDartFirstSeenOnFinalRemovalFrameStaysBackground() {
        let scene = EdgeScene()
        var t = MultiFrameTracker(ignoresDartsAtStart: false)
        for _ in 0..<6 { _ = t.process(scene.frame()) }
        let a = SIMD2(0.0, -60.0), b = SIMD2(60.0, 0.0)
        for _ in 0..<4 { _ = t.process(scene.frame([a])) }
        t.endVisit()
        for _ in 0..<(DetectorTuning.removalFramesNeeded - 1) { _ = t.process(scene.frame()) }
        let clear = t.process(scene.frame([b]))
        XCTAssertTrue(clear.contains(.boardCleared))
        var later: [DetectionEvent] = []
        for _ in 0..<10 { later += t.process(scene.frame([b])) }
        XCTAssertFalse(later.contains { if case .dartDetected = $0 { return true }; return false }, "A tip already present on the board-clear frame belongs to the background, not the next visit")
    }

    func testFirstPartialRelockFrameMustNotFinishRemoval() {
        let scene = EdgeScene()
        var t = MultiFrameTracker(ignoresDartsAtStart: false)
        for _ in 0..<6 { _ = t.process(scene.frame()) }
        for _ in 0..<4 { _ = t.process(scene.frame([SIMD2(0, -60)])) }
        XCTAssertEqual(t.visitDarts.count, 1)
        t.endVisit()
        for _ in 0..<(DetectorTuning.removalFramesNeeded - 1) { XCTAssertFalse(t.process(scene.frame()).contains(.boardCleared)) }
        for _ in 0..<DetectorTuning.lostFramesBeforeUnlock { _ = t.process(scene.frame(calibration: [0, 1])) }
        XCTAssertFalse(t.isLocked)
        var out: [DetectionEvent] = []
        for _ in 0..<DetectorTuning.lockFramesNeeded { out += t.process(scene.frame(calibration: Set(0..<6))) }
        XCTAssertTrue(t.isLocked)
        XCTAssertEqual(t.lastFrameUse, .usable(clearView: false))
        XCTAssertFalse(out.contains(.boardCleared), "Only a partial board was seen after the occlusion")
        XCTAssertEqual(t.phase, .awaitingRemoval)
    }

    func testRepeatedPartialRelocksCannotAccumulateClearEvidence() {
        let scene = EdgeScene()
        var t = MultiFrameTracker(ignoresDartsAtStart: false)
        for _ in 0..<6 { _ = t.process(scene.frame()) }
        for _ in 0..<4 { _ = t.process(scene.frame([SIMD2(0, -60)])) }
        t.endVisit()
        var out: [DetectionEvent] = []
        for _ in 0..<DetectorTuning.removalFramesNeeded {
            for _ in 0..<DetectorTuning.lostFramesBeforeUnlock { out += t.process(scene.frame(calibration: [0, 1])) }
            for _ in 0..<DetectorTuning.lockFramesNeeded { out += t.process(scene.frame(calibration: Set(0..<6))) }
        }
        XCTAssertFalse(out.contains(.boardCleared), "There was never a clear view of the board")
    }
}

@MainActor private final class EdgeFeed: FrameFeed {
    var engine: DetectionEngine?
    func start(engine: DetectionEngine, preview: PreviewHostView, failed: @escaping @MainActor () -> Void) { self.engine = engine }
    func stop() {}
}

@MainActor final class ResumeEdgeCaseTests: XCTestCase {
    private enum NoModel: Error { case test }
    private func drainMain() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
    private func make() async throws -> (RFDetrDetectionSource, DetectionEngine) {
        let feed = EdgeFeed()
        let source = RFDetrDetectionSource(feed: feed, ignoresDartsAtStart: false) { throw NoModel.test }
        source.start()
        let engine = try XCTUnwrap(feed.engine)
        engine.queue.sync {}
        await drainMain()
        return (source, engine)
    }
    func testBatchDartsDroppedOnBustDoNotExhaustTheReopenedVisit() async throws {
        let frame = try TestResources.photo("02491f68-IMG_5656.jpeg")
        let feed = EdgeFeed()
        let source = RFDetrDetectionSource(feed: feed, ignoresDartsAtStart: false)
        let session = GameSession(rules: X01Rules(startScore: 2, doubleOut: true), players: ["A", "B"], source: source)
        session.start()
        let engine = try XCTUnwrap(feed.engine)
        engine.queue.sync { for i in 0..<15 { engine.process(frame, time: 1 + Double(i) / 10) } }
        await drainMain()
        engine.queue.sync {}
        XCTAssertEqual(session.match.activeOutcome, .bust)
        XCTAssertEqual(session.match.activeVisit?.darts.count, 1)
        let first = try XCTUnwrap(session.match.activeVisit?.darts.first)
        session.correct(dartID: first.id, to: .miss)
        XCTAssertEqual(session.match.activeOutcome, .open)
        engine.queue.sync {}
        var tracker = engine.queue.sync {
            Mirror(reflecting: engine).children.first { $0.label == "tracker" }!.value as! MultiFrameTracker
        }
        XCTAssertEqual(tracker.phase, .throwing)
        // All three confirmed tips are kept to block duplicates, but none counts towards the quota.
        XCTAssertEqual(tracker.resumedDarts.count, 3)
        XCTAssertTrue(tracker.visitDarts.isEmpty)
        // Continue the actual engine's tracker value with calibrated frames containing one
        // fresh tip, well away from every restored tip. No model injection or source edit.
        let camera = try XCTUnwrap(tracker.homography?.inverse)
        let tip = [SIMD2(70.0, 0.0), SIMD2(-70.0, 0.0), SIMD2(0.0, -70.0)].first { p in
            tracker.resumedDarts.allSatisfy { simd_distance($0.boardMM, p) > 20 }
        }!
        var ds = (0..<12).map { ModelDetection(classIndex: $0, point: camera.apply(BoardCalibration.targetsMM[$0])!, confidence: 0.9) }
        ds.append(ModelDetection(classIndex: 12, point: camera.apply(tip)!, confidence: 0.8))
        let observation = FrameObservation(imageSize: frame.size, detections: ds)
        var out: [DetectionEvent] = []
        for _ in 0..<20 { out += tracker.process(observation) }
        XCTAssertTrue(out.contains { if case .dartDetected = $0 { return true }; return false }, "The game has two empty slots, but two undelivered darts consume the detector's limit")
        session.stop()
    }

    private var dart: DetectionEvent { .dartDetected(DetectedDart(segment: .single(20), boardPosition: nil, confidence: 0.8)) }

    func testResetThenResumeDropsOldDartAndOldClearButPreservesStatusOrder() async throws {
        let (source, engine) = try await make()
        var got: [DetectionEvent] = []
        source.onEvent = { got.append($0) }
        let d = dart
        engine.queue.sync { engine.output?(.init(events: [.status(.aligning), d, .boardCleared, .status(.ready)], snapshot: nil, generation: 0)) }
        source.reset()
        source.resumeVisit()
        await drainMain()
        XCTAssertEqual(got, [.status(.aligning), .status(.ready)])
        engine.queue.sync { engine.output?(.init(events: [d], snapshot: nil, generation: 2)) }
        await drainMain()
        XCTAssertEqual(got.last, d)
        source.stop()
    }

    func testResumeInsideBatchInvalidatesItsRemainingDartsAndClear() async throws {
        let (source, engine) = try await make()
        var got: [DetectionEvent] = []
        let d = dart
        source.onEvent = { e in
            got.append(e)
            if case .dartDetected = e { source.resumeVisit() }
        }
        engine.queue.sync { engine.output?(.init(events: [d, d, .boardCleared, .status(.ready)], snapshot: nil, generation: 0)) }
        await drainMain()
        XCTAssertEqual(got, [d, .status(.ready)])
        source.stop()
    }
}
