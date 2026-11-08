import Foundation

// X01 rules and match state. Pure value types with no UI or detection dependency,
// so they can be unit tested and driven by any input (camera, demo, manual entry).

struct X01Rules: Hashable, Codable {
    var startScore: Int
    var doubleOut: Bool

    static let standard = X01Rules(startScore: 501, doubleOut: true)
}

/// A point on the board face. Centre is (0, 0); radius 1 is the outer edge of the
/// double ring; +x points to the 6, +y points down to the 3 (screen orientation).
struct BoardPoint: Hashable, Codable {
    var x: Double
    var y: Double

    var radius: Double { (x * x + y * y).squareRoot() }
}

struct Dart: Identifiable, Hashable {
    let id: UUID
    var segment: Segment
    /// Where the detector saw the tip, if it came from the camera.
    var boardPosition: BoardPoint?
    /// Detector confidence 0...1; nil when entered or corrected by hand.
    var confidence: Double?

    init(id: UUID = UUID(), segment: Segment, boardPosition: BoardPoint? = nil, confidence: Double? = nil) {
        self.id = id
        self.segment = segment
        self.boardPosition = boardPosition
        self.confidence = confidence
    }

    var isManual: Bool { confidence == nil }
}

enum VisitOutcome: Equatable {
    /// Fewer than three darts and still in play.
    case open
    /// Visit finished without a bust or a finish.
    case scored
    /// Went below zero, left 1 on double-out, or finished without a double.
    case bust
    /// Reached exactly zero legally.
    case checkout
}

/// One player's turn: up to three darts.
struct Visit: Identifiable, Hashable {
    let id: UUID
    let playerIndex: Int
    let startRemaining: Int
    var darts: [Dart]
    /// The player ended the turn early; the darts not recorded count as misses.
    var endedEarly: Bool
    /// The game has moved on to the next player.
    var isConfirmed: Bool

    init(playerIndex: Int, startRemaining: Int, darts: [Dart] = []) {
        self.id = UUID()
        self.playerIndex = playerIndex
        self.startRemaining = startRemaining
        self.darts = darts
        self.endedEarly = false
        self.isConfirmed = false
    }
}

struct VisitEvaluation: Equatable {
    var outcome: VisitOutcome
    /// Points taken off the remaining score (0 for a bust).
    var scored: Int
    /// Index of the dart that ended the visit (bust, finish or third dart).
    var endIndex: Int?
}

enum X01 {
    /// Scores a sequence of darts thrown from `start` under `rules`.
    static func evaluate(_ segments: [Segment], from start: Int, rules: X01Rules) -> VisitEvaluation {
        var remaining = start
        for (index, segment) in segments.enumerated() {
            let after = remaining - segment.points
            if after < 0 || (rules.doubleOut && after == 1) || (after == 0 && rules.doubleOut && !segment.isDouble) {
                return VisitEvaluation(outcome: .bust, scored: 0, endIndex: index)
            }
            if after == 0 {
                return VisitEvaluation(outcome: .checkout, scored: start, endIndex: index)
            }
            remaining = after
            if index == 2 {
                return VisitEvaluation(outcome: .scored, scored: start - remaining, endIndex: index)
            }
        }
        return VisitEvaluation(outcome: .open, scored: start - remaining, endIndex: nil)
    }

    static func evaluate(_ visit: Visit, rules: X01Rules) -> VisitEvaluation {
        var result = evaluate(visit.darts.map(\.segment), from: visit.startRemaining, rules: rules)
        if result.outcome == .open && visit.endedEarly {
            result.outcome = .scored
        }
        return result
    }

    /// True when one dart can finish `remaining` (a double or the bull on double-out).
    static func isOneDartFinish(_ remaining: Int, doubleOut: Bool) -> Bool {
        if doubleOut { return remaining == 50 || (remaining >= 2 && remaining <= 40 && remaining % 2 == 0) }
        return Segment.allScoring.contains { $0.points == remaining }
    }
}

struct X01Match {
    let rules: X01Rules
    let players: [String]
    private(set) var visits: [Visit] = []

    init(rules: X01Rules, players: [String]) {
        precondition(!players.isEmpty, "A match needs at least one player")
        self.rules = rules
        self.players = players
    }

    // MARK: Derived state

    /// The visit shown on the scoreboard: in progress, or finished but not yet confirmed.
    var activeVisit: Visit? {
        guard let last = visits.last, !last.isConfirmed else { return nil }
        return last
    }

    var activeOutcome: VisitOutcome? {
        activeVisit.map { X01.evaluate($0, rules: rules).outcome }
    }

    var currentPlayerIndex: Int {
        if let active = activeVisit { return active.playerIndex }
        if let last = visits.last { return (last.playerIndex + 1) % players.count }
        return 0
    }

    /// Index of the player who checked out, once the finishing visit is confirmed.
    var winnerIndex: Int? {
        guard let last = visits.last, last.isConfirmed,
              X01.evaluate(last, rules: rules).outcome == .checkout else { return nil }
        return last.playerIndex
    }

    var isOver: Bool { winnerIndex != nil }

    /// Remaining score including the darts of the visit in progress (a bust shows the start score).
    func remaining(for player: Int) -> Int {
        var remaining = rules.startScore
        for visit in visits where visit.playerIndex == player {
            remaining -= X01.evaluate(visit, rules: rules).scored
        }
        return remaining
    }

    /// Remaining score before the player's current visit.
    func remainingBeforeActiveVisit(for player: Int) -> Int {
        if let active = activeVisit, active.playerIndex == player { return active.startRemaining }
        return remaining(for: player)
    }

    /// Darts the current player still has in this visit.
    var dartsLeftInVisit: Int {
        guard let active = activeVisit else { return 3 }
        return activeOutcome == .open ? 3 - active.darts.count : 0
    }

    var canUndo: Bool { !visits.isEmpty }

    // MARK: Actions

    /// Records a dart for the current player. A finished but unconfirmed visit is confirmed first.
    @discardableResult
    mutating func add(_ dart: Dart) -> VisitOutcome {
        guard !isOver else { return .checkout }
        if let outcome = activeOutcome, outcome != .open {
            confirmVisit()
            if isOver { return .checkout }
        }
        if activeVisit == nil {
            let player = currentPlayerIndex
            visits.append(Visit(playerIndex: player, startRemaining: remaining(for: player)))
        }
        visits[visits.count - 1].darts.append(dart)
        return activeOutcome ?? .open
    }

    /// Corrects a dart in the active visit. Darts after a new bust or finish are dropped.
    @discardableResult
    mutating func replaceDart(id: UUID, with segment: Segment) -> VisitOutcome? {
        guard let active = activeVisit,
              let index = active.darts.firstIndex(where: { $0.id == id }) else { return nil }
        let last = visits.count - 1
        visits[last].darts[index].segment = segment
        visits[last].darts[index].confidence = nil
        let evaluation = X01.evaluate(visits[last], rules: rules)
        if let end = evaluation.endIndex, end < visits[last].darts.count - 1 {
            visits[last].darts.removeSubrange((end + 1)...)
        }
        return evaluation.outcome
    }

    /// Ends the current player's visit and moves to the next player.
    /// Darts not thrown or not recorded count as misses.
    mutating func endVisit() {
        guard !isOver else { return }
        if activeVisit == nil {
            let player = currentPlayerIndex
            visits.append(Visit(playerIndex: player, startRemaining: remaining(for: player)))
        }
        let last = visits.count - 1
        if X01.evaluate(visits[last], rules: rules).outcome == .open {
            visits[last].endedEarly = true
        }
        visits[last].isConfirmed = true
    }

    /// Moves on from a finished visit (three darts, bust or checkout).
    mutating func confirmVisit() {
        guard let outcome = activeOutcome, outcome != .open else { return }
        visits[visits.count - 1].isConfirmed = true
    }

    /// Reverses the last action: a confirmed visit is reopened, otherwise the last dart is removed.
    mutating func undo() {
        guard !visits.isEmpty else { return }
        let last = visits.count - 1
        if visits[last].isConfirmed {
            visits[last].isConfirmed = false
            if visits[last].endedEarly {
                visits[last].endedEarly = false
                if visits[last].darts.isEmpty { visits.removeLast() }
            }
            return
        }
        visits[last].darts.removeLast()
        if visits[last].darts.isEmpty { visits.removeLast() }
    }

    // MARK: Checkout help

    /// Suggested finish for the current player with the darts left in this visit.
    /// Nil when no finish is possible or the visit is already over.
    var checkoutSuggestion: [Segment]? {
        guard !isOver, dartsLeftInVisit > 0 else { return nil }
        return CheckoutCalculator.suggestion(for: remaining(for: currentPlayerIndex),
                                             dartsLeft: dartsLeftInVisit,
                                             doubleOut: rules.doubleOut)
    }
}
