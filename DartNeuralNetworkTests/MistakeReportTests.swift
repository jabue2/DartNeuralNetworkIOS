import CoreImage
import ImageIO
import UIKit
import XCTest
@testable import DartNeuralNetwork

private final class SilentSource: DartDetectionSource {
    var status: BoardStatus = .ready
    var onEvent: ((DetectionEvent) -> Void)?
    func start() {}
    func stop() {}
    func endVisit() {}
    func resumeVisit() {}
    func reset() {}
    func makePreviewView() -> UIView { UIView() }
    func detect(_ segment: Segment) {
        onEvent?(.dartDetected(DetectedDart(segment: segment, boardPosition: BoardPoint(x: 0.1, y: -0.2), confidence: 0.9)))
    }
}

/// Replays a saved `detector.json` through the tracker, from the checkpoint the log starts with:
/// the logged detections and commands must give the logged events again (that is what makes a
/// report useful on a Mac).
enum DetectorLogReplay {
    struct Result {
        /// Events per logged frame.
        var events: [[String]]
        /// Later checkpoints that differ from the replayed tracker state.
        var checkpointMismatches: Int
        /// Recorded commands that were applied, in order.
        var appliedCommands: [String] = []
    }

    /// - Parameters:
    ///   - fullVisitTimes: With this, a visit ends when the replayed tracker reports its third dart
    ///     (as the game does), and recorded `endVisit`s that followed the game's third dart (these
    ///     times, from `game.json`) are skipped. Other commands (Next on a short visit, a bust,
    ///     undo, rematch) are replayed as recorded.
    static func replay(_ file: DetectorLogFile, fullVisitTimes: [Double]? = nil) -> Result? {
        guard var tracker = file.entries.first?.checkpoint else { return nil }
        let simulateVisits = fullVisitTimes != nil
        func followsFullVisit(_ time: Double) -> Bool {
            (fullVisitTimes ?? []).contains { time - $0 >= 0 && time - $0 <= 1 }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var result = Result(events: [], checkpointMismatches: 0)
        for entry in file.entries.dropFirst() {
            if let checkpoint = entry.checkpoint {
                if (try? encoder.encode(checkpoint)) != (try? encoder.encode(tracker)) { result.checkpointMismatches += 1 }
                continue
            }
            if let command = entry.command,
               !(command == "endVisit" && simulateVisits && followsFullVisit(entry.time)) {
                result.appliedCommands.append(command)
            }
            switch entry.command {
            case "endVisit" where simulateVisits && followsFullVisit(entry.time):
                break   // the game's third dart ended it; the replay ends visits itself
            case "endVisit": tracker.endVisit()
            case "resumeVisit": tracker.resumeVisit()
            case "reset": tracker.reset()
            case "cameraStopped": tracker.cameraRestarted()
            default: break
            }
            guard let frame = entry.frame else { continue }
            let size = CGSize(width: frame.width, height: frame.height)
            let crop = CGRect(x: frame.crop[0], y: frame.crop[1], width: frame.crop[2], height: frame.crop[3])
            let observation = FrameObservation(
                imageSize: size, crop: crop,
                detections: frame.detections.map { ModelDetection(classIndex: $0.c, point: SIMD2($0.x, $0.y), confidence: $0.p) })
            result.events.append(tracker.process(observation).map(DetectorRecorder.describe))
            if simulateVisits, tracker.phase == .throwing, tracker.visitDarts.count >= DetectorTuning.maxDartsPerVisit {
                tracker.endVisit()
            }
        }
        return result
    }
}

final class DetectorRecorderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func frame() -> DetectorRecorder.Frame {
        .init(width: 100, height: 200, crop: [0, 0, 100, 200], detections: [.init(c: 12, x: 50, y: 60, p: 0.4)],
              events: [], phase: "throwing", use: "clear", status: "ready", homography: nil,
              visitDarts: [], oldDarts: [], inferenceMilliseconds: 40, image: false)
    }

    private static func solidImage(width: Int, height: Int, color: (UInt8, UInt8, UInt8)) -> FrameImage {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        fill(buffer!) { _, _ in color }
        return FrameImage(pixelBuffer: buffer!, orientation: .up)
    }

    /// Fills a BGRA buffer; `color(column, row)` returns RGB.
    private static func fill(_ buffer: CVPixelBuffer, color: (Int, Int) -> (UInt8, UInt8, UInt8)) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            for column in 0..<CVPixelBufferGetWidth(buffer) {
                let (r, g, b) = color(column, row)
                let p = base + row * bytesPerRow + column * 4
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
    }

    private func save(_ recorder: DetectorRecorder) throws -> (DetectorRecorder.Summary, DetectorLogFile) {
        let done = expectation(description: "saved")
        var summary: DetectorRecorder.Summary?
        recorder.save(to: folder) { summary = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let file = try JSONDecoder().decode(DetectorLogFile.self, from: Data(contentsOf: folder.appendingPathComponent("detector.json")))
        return (try XCTUnwrap(summary), file)
    }

    /// The log keeps `logSeconds` back to a checkpoint, images only `imageSeconds`; saving writes both, in order.
    func testKeepsTheLastSecondsAndSavesThem() throws {
        let recorder = DetectorRecorder(logSeconds: 10, imageSeconds: 3)
        let image = Self.solidImage(width: 64, height: 64, color: (200, 30, 30))
        for i in 0..<20 {
            if i % 4 == 0 { recorder.record(checkpoint: MultiFrameTracker(), time: Double(i)) }
            recorder.record(frame: frame(), time: Double(i), image: (image, CGRect(x: 0, y: 0, width: 64, height: 64)))
            recorder.queue.sync {}   // let each image encode, so none is skipped
            if i == 5 { recorder.record(command: "endVisit", time: 5.5) }
        }
        let (summary, file) = try save(recorder)

        // Newest 19: the window starts at 9, cut back to the checkpoint at 8.
        XCTAssertEqual(file.entries.first?.time, 8)
        XCTAssertNotNil(file.entries.first?.checkpoint)
        XCTAssertEqual(file.entries.last?.time, 19)
        XCTAssertEqual(file.entries.map(\.seq), file.entries.map(\.seq).sorted())
        XCTAssertEqual(summary.images, 4, "images of the last 3 s: 16...19")
        let withImage = file.entries.filter { $0.frame?.image == true }.map(\.time)
        XCTAssertEqual(withImage, [16, 17, 18, 19])
        for entry in file.entries where entry.frame?.image == true {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(String(format: "frames/%06d.jpg", entry.seq)).path))
        }
        XCTAssertEqual(file.modelInputSide, DetectorTuning.modelInputSide)
    }

    /// Without a checkpoint to cut at, nothing is trimmed (a replay needs a known start).
    func testNeverTrimsPastTheOnlyCheckpoint() throws {
        let recorder = DetectorRecorder(logSeconds: 2)
        recorder.record(checkpoint: MultiFrameTracker(), time: 0)
        for i in 0..<10 { recorder.record(frame: frame(), time: Double(i), image: nil) }
        let (_, file) = try save(recorder)
        XCTAssertEqual(file.entries.count, 11)
        XCTAssertNotNil(file.entries.first?.checkpoint)
    }

    func testSavesCommandsBetweenFrames() throws {
        let recorder = DetectorRecorder()
        recorder.record(frame: frame(), time: 1, image: nil)
        recorder.record(command: "endVisit", time: 2)
        recorder.record(frame: frame(), time: 3, image: nil)
        let (summary, file) = try save(recorder)
        XCTAssertEqual(file.entries.map { $0.command ?? "frame" }, ["frame", "endVisit", "frame"])
        XCTAssertEqual(summary.images, 0)
        XCTAssertEqual(file.entries[0].frame?.detections, [.init(c: 12, x: 50, y: 60, p: 0.4)])
    }

    /// The camera's buffers are sideways (`.right`): the saved image must show the upright crop,
    /// like the model's input. Upright quadrants: red, green / blue, white.
    func testImageIsTheUprightCropOfASidewaysBuffer() throws {
        let uprightWidth = 120, uprightHeight = 200
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, uprightHeight, uprightWidth, kCVPixelFormatType_32BGRA, attributes, &buffer)
        // Upright (ux, uy) is buffer column uy, row bufferHeight - 1 - ux (as `ModelInputWriter` reads it).
        Self.fill(buffer!) { column, row in
            let ux = uprightWidth - 1 - row, uy = column
            switch (ux < uprightWidth / 2, uy < uprightHeight / 2) {
            case (true, true): return (255, 0, 0)
            case (false, true): return (0, 255, 0)
            case (true, false): return (0, 0, 255)
            case (false, false): return (255, 255, 255)
            }
        }
        let frame = FrameImage(pixelBuffer: buffer!, orientation: .right)
        XCTAssertEqual(frame.size, CGSize(width: uprightWidth, height: uprightHeight))
        let context = CIContext()

        func centre(of region: CGRect) throws -> (Int, Int, Int) {
            let data = try XCTUnwrap(DetectorRecorder.modelInputJPEG(frame, region: region, context: context, side: 64))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 64)
            var pixel = [UInt8](repeating: 0, count: 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: -32, y: -32, width: 64, height: 64))
            return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
        }
        func assertColor(_ c: (Int, Int, Int), _ expected: (Int, Int, Int), _ name: String) {
            XCTAssertLessThan(abs(c.0 - expected.0) + abs(c.1 - expected.1) + abs(c.2 - expected.2), 60, "\(name): got \(c)")
        }
        assertColor(try centre(of: CGRect(x: 10, y: 10, width: 40, height: 80)), (255, 0, 0), "top left")
        assertColor(try centre(of: CGRect(x: 70, y: 10, width: 40, height: 80)), (0, 255, 0), "top right")
        assertColor(try centre(of: CGRect(x: 10, y: 110, width: 40, height: 80)), (0, 0, 255), "bottom left")
        assertColor(try centre(of: CGRect(x: 70, y: 110, width: 40, height: 80)), (255, 255, 255), "bottom right")
    }

    /// A real photo through the engine (frames and commands on the real host clock, as on the phone).
    private func runEngine(recorder: DetectorRecorder, checkpointSeconds: Double)
        throws -> (live: [String], file: DetectorLogFile, summary: DetectorRecorder.Summary) {
        try TestResources.requirePhotos()
        let model = try XCTUnwrap(TestResources.model)
        let photo = try TestResources.photo(try XCTUnwrap(TestResources.photoNames.first))
        let engine = DetectionEngine(ignoresDartsAtStart: false, recorder: recorder, checkpointSeconds: checkpointSeconds) { model }
        var live: [String] = []
        engine.output = { live += $0.events.map(DetectorRecorder.describe) }
        for i in 0..<14 {
            if i == 10 { engine.endVisit(generation: 1) }
            Thread.sleep(forTimeInterval: 0.09)   // above the frame-rate cap
            engine.queue.sync { engine.process(photo, time: CACurrentMediaTime()) }
        }
        let done = expectation(description: "saved")
        var summary: DetectorRecorder.Summary?
        engine.saveRecording(to: folder) { summary = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        let file = try JSONDecoder().decode(DetectorLogFile.self, from: Data(contentsOf: folder.appendingPathComponent("detector.json")))
        return (live, file, try XCTUnwrap(summary))
    }

    /// The report holds the model's detections and images, and replaying its log from the
    /// starting checkpoint gives the same events.
    func testEngineRecordingReplaysToTheSameEvents() throws {
        let (live, file, summary) = try runEngine(recorder: DetectorRecorder(), checkpointSeconds: 30)
        XCTAssertEqual(file.entries.filter { $0.frame != nil }.count, 14)
        XCTAssertEqual(file.entries.compactMap(\.command), ["endVisit"])
        XCTAssertNotNil(file.entries.first?.checkpoint)
        XCTAssertGreaterThan(summary.images, 0)
        XCTAssertTrue(live.contains { $0.hasPrefix("dart ") }, "the photo's darts are reported: \(live)")
        let logged = file.entries.compactMap { $0.frame?.events }
        XCTAssertEqual(logged.flatMap { $0 }, live)
        let replay = try XCTUnwrap(DetectorLogReplay.replay(file))
        XCTAssertEqual(replay.events, logged)
        XCTAssertEqual(replay.checkpointMismatches, 0)
    }

    /// Once the log is trimmed, the replay starts from a later checkpoint and still matches.
    func testTrimmedRecordingStillReplays() throws {
        let (live, file, _) = try runEngine(recorder: DetectorRecorder(logSeconds: 0.3), checkpointSeconds: 0.2)
        let frames = file.entries.filter { $0.frame != nil }.count
        XCTAssertLessThan(frames, 14, "the log was trimmed")
        XCTAssertGreaterThan(frames, 0)
        XCTAssertNotNil(file.entries.first?.checkpoint)
        XCTAssertTrue(live.contains { $0.hasPrefix("dart ") }, "darts were reported before the cut: \(live)")
        let logged = file.entries.compactMap { $0.frame?.events }
        let replay = try XCTUnwrap(DetectorLogReplay.replay(file))
        XCTAssertEqual(replay.events, logged)
        XCTAssertEqual(replay.checkpointMismatches, 0)
    }

    /// Review: a recorded `endVisit` after a bust (the tracker had three darts, the game took one)
    /// is replayed; one after the game's third dart is not.
    func testReplayKeepsABustButNotAFullVisitsEndVisit() throws {
        let three = (0..<3).map { DetectorRecorder.TrackedDart(label: "20", x: Double($0) * 30, y: -80) }
        var full = frame()
        full.visitDarts = three
        let file = DetectorLogFile(modelInputSide: 800, entries: [
            .init(seq: 0, time: 0, checkpoint: MultiFrameTracker()),
            .init(seq: 1, time: 1, frame: full),
            .init(seq: 2, time: 1.1, command: "endVisit"),
        ])
        XCTAssertEqual(try XCTUnwrap(DetectorLogReplay.replay(file, fullVisitTimes: [])).appliedCommands, ["endVisit"], "a bust")
        XCTAssertEqual(try XCTUnwrap(DetectorLogReplay.replay(file, fullVisitTimes: [1.05])).appliedCommands, [], "a full visit")
    }
}

@MainActor
final class MistakeReportTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func session() -> (GameSession, SilentSource) {
        let source = SilentSource()
        let session = GameSession(rules: X01Rules(startScore: 501, doubleOut: true), players: ["Alex", "Sam"], source: source)
        session.reportsRoot = root
        session.start()
        return (session, source)
    }

    private func waitForReport(_ session: GameSession, count: Int) async throws {
        for _ in 0..<200 where session.reportsSaved < count { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(session.reportsSaved, count)
    }

    private func gameFiles() throws -> [MistakeReports.GameFile] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        return try folders.map {
            try JSONDecoder().decode(MistakeReports.GameFile.self, from: Data(contentsOf: $0.appendingPathComponent("game.json")))
        }
    }

    func testReportSavesTheGameAndItsLog() async throws {
        let (session, source) = session()
        source.detect(.single(20))
        source.detect(.single(20))
        let slot = session.match.activeVisit!.darts[1]
        session.correct(dartID: slot.id, to: .triple(20))
        session.reportMistake(from: "phone")
        try await waitForReport(session, count: 1)

        let file = try XCTUnwrap(try gameFiles().first)
        XCTAssertEqual(file.origin, "phone")
        XCTAssertEqual(file.players, ["Alex", "Sam"])
        XCTAssertEqual(file.visits.count, 1)
        XCTAssertEqual(file.visits[0].darts.map(\.label), ["20", "T20"])
        XCTAssertEqual(file.visits[0].darts.map(\.manual), [false, true])
        XCTAssertEqual(file.visits[0].darts[0].x, 0.1)
        XCTAssertEqual(file.log.map(\.text), [
            "camera: 20 (0.90) as dart 1", "camera: 20 (0.90) as dart 2",
            "corrected dart 2: 20 → T20", "report a mistake (phone)",
        ])
        XCTAssertEqual(session.lastReport?.origin, "phone")
        XCTAssertEqual(session.lastReport?.failed, false)
        XCTAssertNil(session.lastReport?.images, "the fake source records no camera")
    }

    /// The web page's button: a "report" action saves a report and the next snapshot confirms it.
    func testWebReportActionSavesAReport() async throws {
        let (session, _) = session()
        let json = Data(#"{"type":"report","leg":"\#(session.legID.uuidString)"}"#.utf8)
        let action = try ScoreboardAction(json: json)
        XCTAssertEqual(action.kind, .report)
        XCTAssertNil(session.scoreboardSnapshot.game?.report)

        session.apply(action)
        try await waitForReport(session, count: 1)
        XCTAssertEqual(try gameFiles().map(\.origin), ["web"])
        let report = try XCTUnwrap(session.scoreboardSnapshot.game?.report)
        XCTAssertEqual(report.id, session.lastReport?.id.uuidString)
        XCTAssertFalse(report.failed)

        // A report for another leg (a page left open from an earlier game) is ignored.
        session.apply(ScoreboardAction(kind: .report, leg: UUID().uuidString))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.reportsSaved, 1)
    }

    func testTwoReportsInOneSecondGetTheirOwnFolders() throws {
        let date = Date()
        let a = try MistakeReports.newFolder(in: root, origin: "web", date: date)
        let b = try MistakeReports.newFolder(in: root, origin: "web", date: date)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(b.lastPathComponent.hasSuffix("_web_2"))
    }
}
