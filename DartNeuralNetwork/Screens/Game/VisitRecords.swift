import Foundation

/// A record of every finished visit, to build a real test set from normal play: one picture of
/// the board with the visit's darts in it, the darts as finally scored (after the player's
/// corrections), and what the camera first reported for each.
///
/// The picture is the detector's best view of the visit (see `DetectorRecorder.saveVisit`): the
/// clear view with the most darts seen while the visit was being thrown, which is the moment
/// before the player walks up to the board. A dart the camera missed is usually still in it,
/// hidden behind another, and the corrected visit says where it went.
///
/// Files live in `Documents/Visits/<session start>/visit_<n>.{json,jpg}` (Files app: On My
/// iPhone › Darts › Visits), and can be copied like reports (see `MistakeReports`). Nothing
/// leaves the phone.
enum VisitRecords {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Visits", isDirectory: true)
    }

    struct Record: Codable {
        struct DartInfo: Codable, Equatable {
            var label: String
            /// Entered or corrected by hand.
            var manual: Bool
            var confidence: Double?
            /// Board units (radius 1 = outer double wire; x right, y down), when the camera saw it.
            var x: Double?
            var y: Double?
        }

        var savedAt: String
        /// Host clock seconds (same clock as the detector log).
        var time: Double
        /// Position of the visit in the leg (0 = first).
        var visit: Int
        var player: Int
        var startRemaining: Int
        /// The darts as scored when the visit was confirmed.
        var darts: [DartInfo]
        /// The darts as the camera reported them, before any correction.
        var camera: [DartInfo]
        var endedEarly: Bool
        /// The detector's best view of the visit (its log entry; `visit_<n>.jpg` is its model
        /// input image). Nil when the source records nothing or had no clear view.
        var board: DetectorRecorder.Entry?
    }
}
