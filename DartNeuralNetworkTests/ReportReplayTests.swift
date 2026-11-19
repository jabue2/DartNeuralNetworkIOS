import XCTest
@testable import DartNeuralNetwork

/// Replays saved mistake reports (`Documents/Reports/*` copied from the phone) through the
/// current tracker and prints, per report, the darts the phone reported and the darts the
/// tracker reports now. Run with `TEST_RUNNER_REPORTS_DIR=<folder> xcodebuild test
/// -only-testing:DartNeuralNetworkTests/ReportReplayTests`; skipped without it.
final class ReportReplayTests: XCTestCase {
    func testReplayReports() throws {
        guard let path = ProcessInfo.processInfo.environment["REPORTS_DIR"] else {
            throw XCTSkip("Set REPORTS_DIR (TEST_RUNNER_REPORTS_DIR for xcodebuild) to a folder of reports")
        }
        let root = URL(fileURLWithPath: path)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("detector.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(folders.isEmpty)
        // When the game took a third dart (the recorded endVisit that follows is the game's
        // reaction to it), from every report's game log.
        struct GameLog: Decodable { struct Line: Decodable { var time: Double; var text: String }; var log: [Line] }
        let fullVisitTimes = Array(Set(folders.flatMap { folder -> [Double] in
            let log = (try? JSONDecoder().decode(GameLog.self, from: Data(contentsOf: folder.appendingPathComponent("game.json"))))?.log ?? []
            return log.filter { $0.text.hasSuffix("as dart 3") }.map(\.time)
        }))
        var lines: [String] = []
        for folder in folders {
            let file = try JSONDecoder().decode(DetectorLogFile.self,
                                                from: Data(contentsOf: folder.appendingPathComponent("detector.json")))
            let replay = try XCTUnwrap(DetectorLogReplay.replay(file, fullVisitTimes: fullVisitTimes), folder.lastPathComponent)
            let frames = file.entries.filter { $0.frame != nil }
            XCTAssertEqual(frames.count, replay.events.count)
            for (entry, now) in zip(frames, replay.events) {
                let then = entry.frame!.events.filter { !$0.hasPrefix("status") }
                let now = now.filter { !$0.hasPrefix("status") }
                guard then != now else { continue }
                lines.append("REPLAY|\(folder.lastPathComponent)|\(entry.seq)|\(String(format: "%.3f", entry.time))|then=\(then.joined(separator: ";"))|now=\(now.joined(separator: ";"))")
            }
            lines.append("REPLAY|\(folder.lastPathComponent)|done|checkpointMismatches=\(replay.checkpointMismatches)")
        }
        let out = root.appendingPathComponent("replay.txt")
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }
}
