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
        let outcome = match.add(Dart(segment: segment))
        Haptics.tap()
        afterDart(outcome)
    }

    func correct(dartID: UUID, to segment: Segment) {
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
        let finishing = match.activeOutcome == .checkout
        match.endVisit()
        visitAwaitingRemoval = match.visits.last?.id
        source.endVisit()
        finishing ? Haptics.success() : Haptics.nextPlayer()
    }

    func undo() {
        guard match.canUndo else { return }
        let undone = match.visits.last?.id
        match.undo()
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
        match = X01Match(rules: match.rules, players: match.players)
        legID = UUID()
        visitAwaitingRemoval = nil
        source.reset()
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
            boardStatus = status
        case .dartDetected(let detected):
            guard !match.isOver, match.activeOutcome != .checkout else { return }
            let outcome = match.add(detected.asDart)
            Haptics.dart()
            afterDart(outcome)
        case .visitEnded:
            // The detector closed the visit itself; its darts get pulled next.
            if visitAwaitingRemoval == nil, let active = match.activeVisit, !active.darts.isEmpty {
                visitAwaitingRemoval = active.id
            }
        case .boardCleared:
            // Darts pulled: move on, unless the leg was just won (that waits for a tap).
            // Only the visit the detector closed can be ended this way.
            let awaited = visitAwaitingRemoval
            visitAwaitingRemoval = nil
            guard let awaited, let active = match.activeVisit, active.id == awaited,
                  let outcome = match.activeOutcome, outcome != .checkout else { return }
            match.endVisit()
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
