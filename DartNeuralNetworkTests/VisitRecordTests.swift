import UIKit
import XCTest
@testable import DartNeuralNetwork

/// Keeps the visit records the session asks it to save.
@MainActor
private final class RecordingSource: DartDetectionSource {
    var status: BoardStatus = .ready
    var onEvent: ((DetectionEvent) -> Void)?
    private(set) var saved: [(record: VisitRecords.Record, folder: URL, name: String)] = []
    func start() {}
    func stop() {}
    func endVisit() {}
    func resumeVisit() {}
    func reset() {}
    func makePreviewView() -> UIView { UIView() }
    func saveVisit(_ record: VisitRecords.Record, into folder: URL, name: String) { saved.append((record, folder, name)) }
    private(set) var recording: [String] = []
    func startSessionRecording(into folder: URL) { recording.append("start \(folder.lastPathComponent)") }
    func stopSessionRecording() { recording.append("stop") }
    func recordSession(logLine: MistakeReports.GameFile.LogLine) { recording.append("log \(logLine.text)") }
    func recordSession(game: MistakeReports.GameFile) { recording.append("game \(game.visits.count)") }

    func detect(_ segment: Segment, confidence: Double = 0.9) {
        onEvent?(.dartDetected(DetectedDart(segment: segment, boardPosition: BoardPoint(x: 0.1, y: -0.2), confidence: confidence)))
    }
}

@MainActor
final class VisitRecordTests: XCTestCase {
    private func session() -> (GameSession, RecordingSource) {
        let source = RecordingSource()
        let session = GameSession(rules: X01Rules(startScore: 501, doubleOut: true), players: ["Alex"], source: source)
        session.visitsRoot = URL(fileURLWithPath: "/tmp/visits-test", isDirectory: true)
        session.start()
        return (session, source)
    }

    /// A visit is recorded once, when confirmed, with the darts as scored and as the camera saw them.
    func testAConfirmedVisitIsRecordedWithItsCorrections() throws {
        let (session, source) = session()
        source.detect(.single(5), confidence: 0.45)
        source.detect(.single(20))
        XCTAssertTrue(source.saved.isEmpty, "not before the visit is confirmed")
        session.correct(dartID: try XCTUnwrap(session.match.activeVisit?.darts.first?.id), to: .single(1))
        session.next()

        XCTAssertEqual(source.saved.count, 1)
        let record = try XCTUnwrap(source.saved.first?.record)
        XCTAssertEqual(record.darts.map(\.label), ["1", "20"])
        XCTAssertEqual(record.darts.map(\.manual), [true, false])
        XCTAssertEqual(record.camera.map(\.label), ["5", "20"])
        XCTAssertEqual(record.camera.first?.confidence, 0.45)
        XCTAssertEqual(record.camera.first?.x, 0.1)
        XCTAssertTrue(record.endedEarly)
        XCTAssertEqual(source.saved.first?.name, "visit_001")
        XCTAssertTrue(source.saved.first?.folder.path.hasPrefix("/tmp/visits-test/") ?? false)
    }

    /// A full visit confirmed by the board clearing is recorded, and so is an empty visit
    /// (Next with nothing entered: every dart missed or unseen).
    func testVisitsConfirmedByTheBoardClearingOrWithoutDartsAreRecorded() throws {
        let (session, source) = session()
        source.detect(.triple(20)); source.detect(.triple(20)); source.detect(.single(1))
        source.onEvent?(.boardCleared)
        session.next()

        XCTAssertEqual(source.saved.map(\.record.darts.count), [3, 0])
        XCTAssertEqual(source.saved.map(\.name), ["visit_001", "visit_002"])
        XCTAssertEqual(source.saved.last?.record.visit, 1)
    }

    /// A finished visit confirmed by entering the next visit's first dart is recorded once.
    func testAVisitConfirmedByTheNextDartIsRecordedOnce() {
        let (session, source) = session()
        source.detect(.single(20)); source.detect(.single(20)); source.detect(.single(20))
        session.enter(.single(5))
        session.next()
        XCTAssertEqual(source.saved.map { $0.record.darts.map(\.label) }, [["20", "20", "20"], ["5"]])
    }

    /// Review S2: a visit Undo reopened and Next confirmed again is saved again under its name
    /// (which also restarts the detector's picture), and the next visit gets the next name.
    func testAVisitConfirmedAgainAfterUndoIsSavedAgain() {
        let (session, source) = session()
        source.detect(.single(20)); source.detect(.single(20))
        session.next()
        session.undo()   // reopens the visit
        session.undo()   // removes its second dart
        session.next()
        source.detect(.single(5))
        session.next()
        XCTAssertEqual(source.saved.map(\.name), ["visit_001", "visit_001", "visit_002"])
        XCTAssertEqual(source.saved.map { $0.record.darts.map(\.label) }, [["20", "20"], ["20"], ["5"]])
    }

    /// The session records from start to stop: every log line, and the match at each confirmation.
    func testTheSessionIsRecordedFromStartToStop() {
        let (session, source) = session()
        source.detect(.single(20))
        session.next()
        session.stop()
        XCTAssertEqual(source.recording.first, "start recording")
        XCTAssertTrue(source.recording.contains("log camera: 20 (0.90) as dart 1"))
        XCTAssertTrue(source.recording.contains("log next"))
        XCTAssertTrue(source.recording.contains("game 1"))
        XCTAssertEqual(source.recording.last, "stop")
    }

    func testNothingIsRecordedWithoutAFolder() {
        let (session, source) = session()
        session.visitsRoot = nil
        source.detect(.single(20))
        session.next()
        XCTAssertTrue(source.saved.isEmpty)
    }
}

/// The detector's side: the best view of each visit.
final class VisitPictureTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func frame(darts: Int, use: String = "clear", phase: String = "throwing") -> DetectorRecorder.Frame {
        let detections = (0..<darts).map { DetectorRecorder.Detection(c: 12, x: Double(10 * $0), y: 5, p: 0.7) }
            + [DetectorRecorder.Detection(c: 12, x: 90, y: 90, p: 0.1)]   // too faint to count
        return .init(width: 64, height: 64, crop: [0, 0, 64, 64], detections: detections, events: [], phase: phase, use: use,
                     status: "ready", homography: nil, visitDarts: [], oldDarts: [], inferenceMilliseconds: 40, image: false)
    }

    private func image() -> FrameImage {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, attributes, &buffer)
        return FrameImage(pixelBuffer: buffer!, orientation: .up)
    }

    private func record() -> VisitRecords.Record {
        .init(savedAt: "", time: 0, visit: 0, player: 0, startRemaining: 501, darts: [], camera: [], endedEarly: false, board: nil)
    }

    private func saved(_ recorder: DetectorRecorder, name: String) throws -> VisitRecords.Record {
        recorder.saveVisit(record(), into: folder, name: name)
        recorder.queue.sync {}
        return try JSONDecoder().decode(VisitRecords.Record.self, from: Data(contentsOf: folder.appendingPathComponent("\(name).json")))
    }

    /// Review, round 3: a visit saved again (Undo, then Next once the darts were pulled) keeps its
    /// picture rather than taking the empty board seen since.
    func testAVisitSavedAgainKeepsItsPicture() throws {
        let recorder = DetectorRecorder()
        let region = CGRect(x: 0, y: 0, width: 64, height: 64)
        recorder.record(frame: frame(darts: 3), time: 0, image: (image(), region)); recorder.queue.sync {}
        _ = try saved(recorder, name: "visit_001")
        recorder.record(frame: frame(darts: 0), time: 1, image: (image(), region)); recorder.queue.sync {}
        XCTAssertEqual(try saved(recorder, name: "visit_001").board?.time, 0)
        recorder.record(frame: frame(darts: 1), time: 2, image: (image(), region)); recorder.queue.sync {}
        XCTAssertEqual(try saved(recorder, name: "visit_002").board?.time, 2)
    }

    /// Review, round 4: the same for a visit saved long ago (Undo back over several visits).
    func testAVisitSavedAgainAfterOthersKeepsItsPicture() throws {
        let recorder = DetectorRecorder()
        let region = CGRect(x: 0, y: 0, width: 64, height: 64)
        for n in 1...5 {
            recorder.record(frame: frame(darts: 3), time: Double(n), image: (image(), region)); recorder.queue.sync {}
            _ = try saved(recorder, name: String(format: "visit_%03d", n))
        }
        recorder.record(frame: frame(darts: 0), time: 99, image: (image(), region)); recorder.queue.sync {}
        XCTAssertEqual(try saved(recorder, name: "visit_001").board?.time, 1)
    }

    /// A recorded session holds every entry from the last checkpoint on, one per line, and every
    /// image, so the whole session replays on a Mac; a later start moves it to the new folder.
    func testASessionRecordingHoldsEveryEntryAndImage() throws {
        let recorder = DetectorRecorder()
        let region = CGRect(x: 0, y: 0, width: 64, height: 64)
        recorder.record(frame: frame(darts: 1), time: 0, image: (image(), region)); recorder.queue.sync {}
        recorder.record(checkpoint: MultiFrameTracker(), time: 1)
        recorder.record(frame: frame(darts: 2), time: 2, image: (image(), region)); recorder.queue.sync {}
        recorder.startStreaming(into: folder)
        recorder.record(command: "endVisit", time: 3)
        recorder.record(frame: frame(darts: 3), time: 4, image: (image(), region)); recorder.queue.sync {}

        let lines = try String(contentsOf: folder.appendingPathComponent("detector.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(DetectorRecorder.Entry.self, from: Data($0.utf8)) }
        XCTAssertEqual(lines.map(\.time), [1, 2, 3, 4], "from the last checkpoint on")
        XCTAssertNotNil(lines.first?.checkpoint)
        XCTAssertEqual(lines[2].command, "endVisit")
        for entry in lines where entry.frame != nil {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(format: "frames/%06d.jpg", entry.seq)).path))
        }

        // Started again in the same folder (the session restarted): nothing is written twice.
        recorder.startStreaming(into: folder)
        recorder.stopStreaming()
        recorder.startStreaming(into: folder)
        recorder.record(command: "resumeVisit", time: 6)
        recorder.recordGame(logLine: .init(time: 6, text: "camera: 5 (0.80) as dart 1"))
        recorder.queue.sync {}
        let again = try String(contentsOf: folder.appendingPathComponent("detector.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(DetectorRecorder.Entry.self, from: Data($0.utf8)) }
        XCTAssertEqual(again.map(\.time), [1, 2, 3, 4, 6])
        XCTAssertEqual(Set(again.map(\.seq)).count, again.count)
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("game_log.jsonl"), encoding: .utf8).contains("as dart 1"))

        let next = folder.appendingPathComponent("next", isDirectory: true)
        recorder.startStreaming(into: next)
        recorder.record(command: "reset", time: 5); recorder.queue.sync {}
        let before = try String(contentsOf: folder.appendingPathComponent("detector.jsonl"), encoding: .utf8)
        XCTAssertFalse(before.contains("\"reset\""))
        XCTAssertTrue(try String(contentsOf: next.appendingPathComponent("detector.jsonl"), encoding: .utf8).contains("\"reset\""))

        // Stopped: nothing more is written.
        recorder.stopStreaming()
        recorder.record(command: "cameraStopped", time: 7); recorder.queue.sync {}
        XCTAssertFalse(try String(contentsOf: next.appendingPathComponent("detector.jsonl"), encoding: .utf8).contains("cameraStopped"))
    }

    /// Review: a game stopped and started again at once keeps recording; the stop does not
    /// overtake the start.
    func testAQuickStopAndStartKeepsRecording() throws {
        struct NoModel: Error {}
        let engine = DetectionEngine(ignoresDartsAtStart: false, loadModel: { throw NoModel() })
        engine.startSessionRecording(into: folder)
        engine.stopSessionRecording()
        engine.startSessionRecording(into: folder)
        engine.endVisit(generation: 1)
        engine.queue.sync {}
        engine.recorder.queue.sync {}
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("detector.jsonl"), encoding: .utf8).contains("endVisit"))
    }

    /// The clear view with the most darts while throwing; not a partial view, not one after the
    /// visit closed, and on a tie the later one.
    func testSavesTheClearViewWithTheMostDarts() throws {
        let recorder = DetectorRecorder()
        let frames = [frame(darts: 1), frame(darts: 3), frame(darts: 3), frame(darts: 4, use: "usable"),
                      frame(darts: 5, phase: "awaitingRemoval"), frame(darts: 0)]
        for (i, f) in frames.enumerated() {
            recorder.record(frame: f, time: Double(i), image: (image(), CGRect(x: 0, y: 0, width: 64, height: 64)))
            recorder.queue.sync {}   // let each image encode
        }
        let first = try saved(recorder, name: "visit_001")
        XCTAssertEqual(first.board?.time, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("visit_001.jpg").path))

        // The next visit starts over: nothing seen since, no picture.
        let second = try saved(recorder, name: "visit_002")
        XCTAssertNil(second.board)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("visit_002.jpg").path))
    }
}
