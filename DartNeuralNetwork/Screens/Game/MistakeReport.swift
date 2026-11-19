import Foundation
import QuartzCore

/// "Report a mistake": when the score went wrong, the player taps the button (on the phone or the
/// web scoreboard) and the app saves a folder for checking on a Mac:
///
/// - `game.json`: the match's visits with every dart (camera or by hand, tip position,
///   confidence) and a log of what happened in the game (darts, corrections, Next, Undo).
/// - `detector.json` and `frames/`: the detector's last seconds (see `DetectorRecorder`).
///
/// Folders live in `Documents/Reports/<date>_<time>_<origin>/`. They show in the Files app
/// (On My iPhone › Darts) and can be copied with
/// `xcrun devicectl device copy from --domain-type appDataContainer --source Documents/Reports`.
enum MistakeReports {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reports", isDirectory: true)
    }

    static func newFolder(in root: URL, origin: String, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var folder = root.appendingPathComponent("\(formatter.string(from: date))_\(origin)", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(formatter.string(from: date))_\(origin)_\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `game.json`.
    struct GameFile: Codable {
        struct DartInfo: Codable {
            var label: String
            /// Entered or corrected by hand.
            var manual: Bool
            var confidence: Double?
            /// Board units (radius 1 = outer double wire; x right, y down), when the camera saw it.
            var x: Double?
            var y: Double?
        }
        struct VisitInfo: Codable {
            var player: Int
            var startRemaining: Int
            var darts: [DartInfo]
            var endedEarly: Bool
            var confirmed: Bool
        }
        struct LogLine: Codable, Equatable {
            /// Host clock seconds, same clock as `detector.json`.
            var time: Double
            var text: String
        }

        var savedAt: String
        /// Host clock seconds when the button was pressed.
        var time: Double
        /// "phone" or "web".
        var origin: String
        var startScore: Int
        var doubleOut: Bool
        var players: [String]
        var currentPlayer: Int
        var visits: [VisitInfo]
        var log: [LogLine]
        var app: String
    }

    static func gameFile(match: X01Match, log: [GameFile.LogLine], origin: String, time: Double, date: Date) -> GameFile {
        let visits = match.visits.map { visit in
            GameFile.VisitInfo(
                player: visit.playerIndex, startRemaining: visit.startRemaining,
                darts: visit.darts.map {
                    GameFile.DartInfo(label: $0.segment.label, manual: $0.isManual, confidence: $0.confidence,
                                      x: $0.boardPosition?.x, y: $0.boardPosition?.y)
                },
                endedEarly: visit.endedEarly, confirmed: visit.isConfirmed)
        }
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        return GameFile(savedAt: ISO8601DateFormatter().string(from: date), time: time, origin: origin,
                        startScore: match.rules.startScore, doubleOut: match.rules.doubleOut,
                        players: match.players, currentPlayer: match.currentPlayerIndex,
                        visits: visits, log: log, app: app)
    }
}

/// The outcome of the last "Report a mistake", for the confirmation on both screens.
struct MistakeReportResult: Equatable {
    let id = UUID()
    /// "phone" or "web".
    var origin: String
    /// Camera images saved; nil when the detector had nothing to save (demo) or saving it failed.
    var images: Int?
    /// Nothing could be saved.
    var failed: Bool

    var message: String {
        if failed { return "Could not save the report" }
        if let images, images > 0 { return "Saved – the last \(Int(DetectorRecorder.defaultImageSeconds)) seconds are kept for checking" }
        return "Saved the game (no camera recording)"
    }
}

extension DetectorRecorder {
    static let defaultImageSeconds = 45.0
}
