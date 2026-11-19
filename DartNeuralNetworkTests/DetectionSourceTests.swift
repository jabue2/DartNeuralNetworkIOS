import XCTest
@testable import DartNeuralNetwork

/// A feed whose frames the test pushes into the engine itself.
@MainActor
private final class ManualFeed: FrameFeed {
    private(set) var engine: DetectionEngine?
    private(set) var startCount = 0
    func start(engine: DetectionEngine, preview: PreviewHostView, failed: @escaping @MainActor () -> Void) {
        self.engine = engine
        startCount += 1
    }
    func stop() {}
}

/// `RFDetrDetectionSource` with the game: command barriers and model-load failures.
@MainActor
final class DetectionSourceTests: XCTestCase {
    /// Lets every block already queued on the main queue run.
    private func drainMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Waits until the engine's queue and then the main queue ran what they had.
    private func settle(_ source: RFDetrDetectionSource, _ feed: ManualFeed) async throws {
        try XCTUnwrap(feed.engine).queue.sync {}
        await drainMain()
    }

    // MARK: Command barriers (review finding 1)

    /// Darts the engine found before a rematch must not score in the new game, even when the
    /// rematch comes while their events still wait on the main queue.
    func testResetDropsDartEventsStillPendingFromTheOldGame() async throws {
        let frame = try TestResources.photo("02491f68-IMG_5656.jpeg")
        let feed = ManualFeed()
        let source = RFDetrDetectionSource(feed: feed, ignoresDartsAtStart: false)
        let session = GameSession(rules: X01Rules(startScore: 501, doubleOut: true), players: ["A", "B"], source: source)
        session.start()
        let engine = try XCTUnwrap(feed.engine)
        engine.queue.sync { for i in 0..<15 { engine.process(frame, time: 1 + Double(i) / 10) } }
        XCTAssertTrue(session.match.visits.isEmpty, "the events are still pending on the main queue")
        session.rematch()
        await drainMain()
        XCTAssertTrue(session.match.visits.isEmpty, "frames from before the reset must not score darts in the rematch")
        XCTAssertEqual(session.boardStatus, .ready, "status events are still delivered")
        session.stop()
    }

    /// A bust on the first dart of a batch ends the visit; the batch's other darts must not open
    /// the next player's visit.
    func testBustOnTheFirstDartDropsTheRestOfThePendingBatch() async throws {
        let frame = try TestResources.photo("02491f68-IMG_5656.jpeg")
        let feed = ManualFeed()
        let source = RFDetrDetectionSource(feed: feed, ignoresDartsAtStart: false)
        let session = GameSession(rules: X01Rules(startScore: 2, doubleOut: true), players: ["A", "B"], source: source)
        session.start()
        let engine = try XCTUnwrap(feed.engine)
        engine.queue.sync { for i in 0..<15 { engine.process(frame, time: 1 + Double(i) / 10) } }
        await drainMain()
        XCTAssertEqual(session.match.visits.count, 1, "the remaining pending darts must not open another player's visit")
        XCTAssertEqual(session.match.activeVisit?.playerIndex, 0)
        XCTAssertEqual(session.match.activeVisit?.darts.count, 1)
        XCTAssertEqual(session.match.activeOutcome, .bust)
        session.stop()
    }

    // MARK: Model-load failure (review finding 8)

    private enum LoadFailure: Error { case simulated }

    /// A failed load shows `.detectorUnavailable`; the next `start()` loads again and recovers.
    func testModelLoadFailureIsReportedAndRetriedOnStart() async throws {
        var attempts = 0
        var fails = true
        let feed = ManualFeed()
        let source = RFDetrDetectionSource(feed: feed, ignoresDartsAtStart: false) {
            attempts += 1
            if fails { throw LoadFailure.simulated }
            return try XCTUnwrap(TestResources.model, "model did not load")
        }
        var statuses: [BoardStatus] = []
        source.onEvent = { if case .status(let s) = $0 { statuses.append(s) } }
        source.start()
        try await settle(source, feed)
        XCTAssertEqual(source.status, .detectorUnavailable)
        XCTAssertEqual(statuses, [.detectorUnavailable])
        let failedAttempts = attempts
        XCTAssertGreaterThanOrEqual(failedAttempts, 1)

        // Frames meanwhile do not try to load on every frame.
        let engine = try XCTUnwrap(feed.engine)
        let blank = try XCTUnwrap(FrameImage.make(from: Self.blankImage()))
        engine.queue.sync { for i in 0..<5 { engine.process(blank, time: 100 + Double(i) / 10) } }
        XCTAssertEqual(attempts, failedAttempts)

        fails = false
        source.stop()
        source.start()
        try await settle(source, feed)
        XCTAssertEqual(attempts, failedAttempts + 1)
        XCTAssertEqual(source.status, .searching)
        XCTAssertEqual(statuses.last, .searching)
        source.stop()
    }

    /// Without a restart, a failed load is tried again once `modelRetrySeconds` of frames passed.
    func testModelLoadIsRetriedWhileFramesArrive() async throws {
        var attempts = 0
        let feed = ManualFeed()
        let source = RFDetrDetectionSource(feed: feed, ignoresDartsAtStart: false) {
            attempts += 1
            throw LoadFailure.simulated
        }
        source.start()
        try await settle(source, feed)
        let afterStart = attempts
        let engine = try XCTUnwrap(feed.engine)
        let blank = try XCTUnwrap(FrameImage.make(from: Self.blankImage()))
        let retry = DetectorTuning.modelRetrySeconds
        engine.queue.sync {
            engine.process(blank, time: 10)                    // starts the wait
            engine.process(blank, time: 10 + retry - 0.5)      // too early
        }
        XCTAssertEqual(attempts, afterStart)
        engine.queue.sync { engine.process(blank, time: 10 + retry + 0.1) }
        XCTAssertEqual(attempts, afterStart + 1)
        await drainMain()
        XCTAssertEqual(source.status, .detectorUnavailable)
        source.stop()
    }

    private static func blankImage() -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return context.makeImage()!
    }
}
