import QuartzCore
import SwiftUI

/// Connects a detection source to an X01 match and exposes the actions of the game screen.
@MainActor
final class GameSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var match: X01Match
    @Published private(set) var boardStatus: BoardStatus
    let source: DartDetectionSource
    /// The visit the detector was told to close and whose darts it waits to see pulled.
    /// A `.boardCleared` only acts on this visit, so a late event cannot end another player's visit.
    private var visitAwaitingRemoval: UUID?
    /// Changes with every new leg (rematch), so a stale edit from another screen is not applied to it.
    private(set) var legID = UUID()
    /// What happened in the game (darts, corrections, Next, Undo), for mistake reports.
    private(set) var log: [MistakeReports.GameFile.LogLine] = []
    static let logLimit = 500
    /// The last "Report a mistake", for the confirmation on the phone and the web page.
    @Published private(set) var lastReport: MistakeReportResult?
    @Published private(set) var reportsSaved = 0
    /// Where reports are saved; tests use a temporary folder.
    var reportsRoot = MistakeReports.defaultRoot
    /// Where finished visits are recorded (see `VisitRecords`); nil records nothing.
    var visitsRoot: URL? = VisitRecords.defaultRoot
    /// This session's folder under `visitsRoot`, named when the session was created.
    private let visitsFolderName: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }()
    /// File name of each visit recorded, and the visits whose current confirmation is recorded.
    private var visitRecordNames: [UUID: String] = [:]
    private var recordedConfirmations: Set<UUID> = []
    /// The darts the camera reported per visit, before corrections.
    private var cameraDarts: [UUID: [DetectedDart]] = [:]

    init(match: X01Match, source: DartDetectionSource) {
        self.match = match
        self.source = source
        self.boardStatus = source.status
    }

    convenience init(rules: X01Rules, players: [String], source: DartDetectionSource) {
        self.init(match: X01Match(rules: rules, players: players), source: source)
    }

    func start() {
        source.onEvent = { [weak self] event in self?.handle(event) }
        boardStatus = source.status
        source.start()
    }

    func stop() {
        source.stop()
        source.onEvent = nil
    }

    // MARK: Actions from the UI

    /// Enters a dart by hand into the next empty slot.
    func enter(_ segment: Segment) {
        note("by hand: \(segment.label) as dart \((match.activeVisit?.darts.count ?? 0) + 1)")
        let outcome = match.add(Dart(segment: segment))
        recordConfirmedVisits()   // adding a dart confirms a finished visit
        Haptics.tap()
        afterDart(outcome)
    }

    func correct(dartID: UUID, to segment: Segment) {
        if let darts = match.activeVisit?.darts, let i = darts.firstIndex(where: { $0.id == dartID }) {
            note("corrected dart \(i + 1): \(darts[i].segment.label) → \(segment.label)")
        }
        guard let outcome = match.replaceDart(id: dartID, with: segment) else { return }
        Haptics.tap()
        if outcome == .open { resumeDetectionIfReopened() } else { afterDart(outcome) }
    }

    /// Identifies the visit a slot belongs to: the active visit, or the one the next dart opens.
    var currentVisitNumber: Int { match.activeVisit == nil ? match.visits.count : match.visits.count - 1 }

    /// Sets a slot chosen in the picker. The picker may have been opened before a detection
    /// filled that slot or before the visit changed, so the target is resolved now.
    func set(slot index: Int, ofVisit visitNumber: Int, to segment: Segment) {
        guard visitNumber == currentVisitNumber else { return }   // the visit moved on: stale choice
        let darts = match.activeVisit?.darts ?? []
        if index < darts.count {
            correct(dartID: darts[index].id, to: segment)
        } else if index == darts.count, (match.activeOutcome ?? .open) == .open {
            enter(segment)
        }
    }

    /// Ends the visit (or finishes the leg after a checkout).
    func next() {
        guard !match.isOver else { return }
        note("next")
        let finishing = match.activeOutcome == .checkout
        match.endVisit()
        recordConfirmedVisits()
        visitAwaitingRemoval = match.visits.last?.id
        source.endVisit()
        finishing ? Haptics.success() : Haptics.nextPlayer()
    }

    func undo() {
        guard match.canUndo else { return }
        note("undo")
        let undone = match.visits.last?.id
        match.undo()
        recordConfirmedVisits()   // a reopened visit is saved again when confirmed again
        Haptics.tap()
        // Reopen detection when the undo touched the visit the detector closed and that visit is
        // either open again or gone (undoing its only dart removes it).
        guard let awaited = visitAwaitingRemoval, awaited == undone else { return }
        let gone = !match.visits.contains { $0.id == awaited }
        if gone || (match.activeVisit?.id == awaited && match.activeOutcome == .open) {
            visitAwaitingRemoval = nil
            source.resumeVisit()
        }
    }

    func rematch() {
        note("rematch")
        match = X01Match(rules: match.rules, players: match.players)
        legID = UUID()
        visitAwaitingRemoval = nil
        source.reset()
    }

    // MARK: Mistake reports

    /// Saves the game and the detector's last seconds for checking on a Mac (see `MistakeReports`).
    func reportMistake(from origin: String) {
        let time = CACurrentMediaTime(), date = Date()
        note("report a mistake (\(origin))")
        let folder: URL
        do {
            folder = try MistakeReports.newFolder(in: reportsRoot, origin: origin, date: date)
            let file = MistakeReports.gameFile(match: match, log: log, origin: origin, time: time, date: date)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: folder.appendingPathComponent("game.json"))
        } catch {
            print("Saving a mistake report failed: \(error)")
            lastReport = MistakeReportResult(origin: origin, images: nil, failed: true)
            Haptics.bust()
            return
        }
        Haptics.success()
        Task {
            let summary = await source.saveRecording(into: folder)
            reportsSaved += 1
            lastReport = MistakeReportResult(origin: origin, images: summary?.images, failed: false)
        }
    }

    /// Adds a line to the game log.
    func note(_ text: String) {
        log.append(.init(time: CACurrentMediaTime(), text: text))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    /// Saves each visit confirmed since the last call, with the darts as scored and as the camera
    /// saw them (see `VisitRecords`). A visit that Undo reopened and that is confirmed again is
    /// saved again under its name, as it is now; each save also starts the detector's search for
    /// the next visit's picture.
    private func recordConfirmedVisits() {
        guard let root = visitsRoot else { return }
        let confirmed = Set(match.visits.filter(\.isConfirmed).map(\.id))
        recordedConfirmations.formIntersection(confirmed)
        for (index, visit) in match.visits.enumerated() where visit.isConfirmed && !recordedConfirmations.contains(visit.id) {
            recordedConfirmations.insert(visit.id)
            let name = visitRecordNames[visit.id] ?? String(format: "visit_%03d", visitRecordNames.count + 1)
            visitRecordNames[visit.id] = name
            func info(_ dart: Dart) -> VisitRecords.Record.DartInfo {
                .init(label: dart.segment.label, manual: dart.isManual, confidence: dart.confidence,
                      x: dart.boardPosition?.x, y: dart.boardPosition?.y)
            }
            let record = VisitRecords.Record(
                savedAt: ISO8601DateFormatter().string(from: Date()), time: CACurrentMediaTime(),
                visit: index, player: visit.playerIndex, startRemaining: visit.startRemaining,
                darts: visit.darts.map(info), camera: (cameraDarts[visit.id] ?? []).map { info($0.asDart) },
                endedEarly: visit.endedEarly, board: nil)
            source.saveVisit(record, into: root.appendingPathComponent(visitsFolderName, isDirectory: true), name: name)
        }
    }

    /// Undo or a correction turned the visit the detector closed back into an open one.
    private func resumeDetectionIfReopened() {
        guard let id = visitAwaitingRemoval, match.activeVisit?.id == id else { return }
        visitAwaitingRemoval = nil
        source.resumeVisit()
    }

    // MARK: Detection

    private func handle(_ event: DetectionEvent) {
        switch event {
        case .status(let status):
            if status != boardStatus { note("board \(ScoreboardSnapshot.name(of: status))") }
            boardStatus = status
        case .dartDetected(let detected):
            guard !match.isOver, match.activeOutcome != .checkout else {
                note("camera: \(detected.segment.label) ignored (leg finished)")
                return
            }
            note(String(format: "camera: %@ (%.2f) as dart %d", detected.segment.label, detected.confidence,
                        (match.activeVisit?.darts.count ?? 0) + 1))
            let outcome = match.add(detected.asDart)
            if let visit = match.activeVisit?.id { cameraDarts[visit, default: []].append(detected) }
            recordConfirmedVisits()   // adding a dart confirms a finished visit
            Haptics.dart()
            afterDart(outcome)
        case .visitEnded:
            note("camera: visit ended (darts pulled)")
            // The detector closed the visit itself; its darts get pulled next.
            if visitAwaitingRemoval == nil, let active = match.activeVisit, !active.darts.isEmpty {
                visitAwaitingRemoval = active.id
            }
        case .emptyVisitEnded:
            // The player walked up to the board with no dart of this visit seen: the visit is over,
            // like Next (its empty slots are misses). Not after a checkout (that waits for a tap),
            // and not while the game waits for a visit's darts to be pulled.
            guard !match.isOver, visitAwaitingRemoval == nil, (match.activeOutcome ?? .open) == .open else {
                note("camera: walked up without darts (ignored)")
                return
            }
            note("camera: visit ended (walked up, no darts seen)")
            match.endVisit()
            recordConfirmedVisits()
            Haptics.nextPlayer()
        case .boardCleared:
            note("camera: board cleared")
            // Darts pulled: move on, unless the leg was just won (that waits for a tap).
            // Only the visit the detector closed can be ended this way.
            let awaited = visitAwaitingRemoval
            visitAwaitingRemoval = nil
            guard let awaited, let active = match.activeVisit, active.id == awaited,
                  let outcome = match.activeOutcome, outcome != .checkout else { return }
            match.endVisit()
            recordConfirmedVisits()
            Haptics.nextPlayer()
        }
    }

    private func afterDart(_ outcome: VisitOutcome) {
        switch outcome {
        case .open:
            return
        case .scored:
            break
        case .bust:
            Haptics.bust()
        case .checkout:
            Haptics.success()
        }
        visitAwaitingRemoval = match.activeVisit?.id
        source.endVisit()
    }
}
