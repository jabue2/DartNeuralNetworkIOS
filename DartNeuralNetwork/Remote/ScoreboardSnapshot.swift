import Foundation

/// What the web scoreboard shows: the game as plain JSON, built from the same match the phone shows.
/// The page renders it as is; every number here is computed by the app, never by the page.
struct ScoreboardSnapshot: Codable, Equatable {
    struct Player: Codable, Equatable {
        var name: String
        /// Live remaining score, including the darts of the visit in progress.
        var remaining: Int
        /// Remaining score before the player's current visit (what the players strip shows).
        var remainingBefore: Int
        var average: Double
        var dartsThrown: Int
        var bestVisit: Int
        var oneEighties: Int
        /// Share of darts at a double that won the leg, nil before any dart at a double.
        var checkoutRate: Double?
    }

    struct DartInfo: Codable, Equatable {
        /// "T20", "D16", "19", "25", "Bull", "Miss" (also what `ScoreboardAction.set` accepts).
        var label: String
        /// "single", "double", "treble", "outerBull", "bull" or "miss", for colouring.
        var ring: String
        var points: Int
        /// Entered or corrected by hand rather than seen by the camera.
        var manual: Bool
    }

    struct VisitInfo: Codable, Equatable {
        var player: Int
        var darts: [DartInfo]
        /// "open", "scored", "bust" or "checkout".
        var outcome: String
        /// Points taken off (0 for a bust).
        var scored: Int
        /// Ended with fewer than three darts recorded; the rest count as misses.
        var endedEarly: Bool
    }

    struct Game: Codable, Equatable {
        /// Identifies the leg (game and rematch); sent back with actions.
        var leg: String
        var startScore: Int
        var doubleOut: Bool
        var players: [Player]
        var current: Int
        /// Identifies the visit a slot belongs to; sent back with `set` so a stale edit is ignored.
        var visitNumber: Int
        /// The big number: the live remaining score, or the score checked out.
        var shown: Int
        /// The visit on the scoreboard, nil before the first dart of a visit.
        var visit: VisitInfo?
        var dartsLeft: Int
        var checkout: [DartInfo]?
        var canUndo: Bool
        var winner: Int?
        /// Confirmed visits, newest first (at most `recentLimit`).
        var recent: [VisitInfo]
        /// The last "Report a mistake"; the page confirms it when `id` changes.
        var report: ReportInfo? = nil
    }

    struct ReportInfo: Codable, Equatable {
        var id: String
        var message: String
        var failed: Bool
    }

    var game: Game?
    /// "ready", "aligning", "searching", "cameraUnavailable", "detectorUnavailable", or "none" without a game.
    var board: String

    static let recentLimit = 12

    static let noGame = ScoreboardSnapshot(game: nil, board: "none")

    init(game: Game?, board: String) {
        self.game = game
        self.board = board
    }

    init(match: X01Match, leg: String, visitNumber: Int, board: BoardStatus) {
        let rules = match.rules
        let players = match.players.indices.map { index -> Player in
            let stats = match.stats(for: index)
            return Player(name: match.players[index],
                          remaining: match.remaining(for: index),
                          remainingBefore: match.remainingBeforeActiveVisit(for: index),
                          average: stats.threeDartAverage,
                          dartsThrown: stats.dartsThrown,
                          bestVisit: stats.bestVisit,
                          oneEighties: stats.oneEighties,
                          checkoutRate: stats.checkoutRate)
        }
        let outcome = match.activeOutcome
        let current = match.currentPlayerIndex
        let shown = outcome == .checkout ? (match.activeVisit?.startRemaining ?? 0) : match.remaining(for: current)
        let recent = match.visits.reversed().filter(\.isConfirmed).prefix(Self.recentLimit)
            .map { Self.visitInfo($0, rules: rules) }
        game = Game(leg: leg,
                    startScore: rules.startScore,
                    doubleOut: rules.doubleOut,
                    players: players,
                    current: current,
                    visitNumber: visitNumber,
                    shown: shown,
                    visit: match.activeVisit.map { Self.visitInfo($0, rules: rules) },
                    dartsLeft: match.dartsLeftInVisit,
                    checkout: match.checkoutSuggestion?.map { Self.dartInfo($0, manual: false) },
                    canUndo: match.canUndo,
                    winner: match.winnerIndex,
                    recent: Array(recent))
        self.board = Self.name(of: board)
    }

    static func name(of status: BoardStatus) -> String {
        switch status {
        case .cameraUnavailable: return "cameraUnavailable"
        case .detectorUnavailable: return "detectorUnavailable"
        case .searching: return "searching"
        case .aligning: return "aligning"
        case .ready: return "ready"
        }
    }

    private static func visitInfo(_ visit: Visit, rules: X01Rules) -> VisitInfo {
        let evaluation = X01.evaluate(visit, rules: rules)
        let outcome: String
        switch evaluation.outcome {
        case .open: outcome = "open"
        case .scored: outcome = "scored"
        case .bust: outcome = "bust"
        case .checkout: outcome = "checkout"
        }
        return VisitInfo(player: visit.playerIndex,
                         darts: visit.darts.map { dartInfo($0.segment, manual: $0.isManual) },
                         outcome: outcome,
                         scored: evaluation.scored,
                         endedEarly: visit.endedEarly)
    }

    private static func dartInfo(_ segment: Segment, manual: Bool) -> DartInfo {
        let ring: String
        switch segment {
        case .miss: ring = "miss"
        case .single: ring = "single"
        case .double: ring = "double"
        case .triple: ring = "treble"
        case .outerBull: ring = "outerBull"
        case .bull: ring = "bull"
        }
        return DartInfo(label: segment.label, ring: ring, points: segment.points, manual: manual)
    }
}

/// A change sent from the web scoreboard. The JSON mirrors the buttons of the game screen, and
/// every action names the leg it was meant for (`Game.leg`); `set` and `next` also name the visit
/// (`Game.visitNumber`), so a stale or repeated click does nothing:
/// `{"type":"set","leg":"…","visit":7,"slot":1,"segment":"T20"}`, `{"type":"next","leg":"…","visit":7}`,
/// `{"type":"undo","leg":"…"}`, `{"type":"rematch","leg":"…"}`, `{"type":"report","leg":"…"}`.
struct ScoreboardAction: Equatable {
    enum Kind: Equatable {
        /// Sets dart `slot` (0...2) of the visit.
        case set(slot: Int, segment: Segment)
        case next
        case undo
        /// Only after the leg is won, so a stray click cannot wipe a game in progress.
        case rematch
        /// "Report a mistake": saves the game and the detector's last seconds.
        case report
    }
    var kind: Kind
    var leg: String
    /// Required for `set` and `next`.
    var visit: Int?

    init(kind: Kind, leg: String, visit: Int? = nil) {
        self.kind = kind
        self.leg = leg
        self.visit = visit
    }

    enum DecodeError: Error { case invalid }

    init(json: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let type = object["type"] as? String,
              let leg = object["leg"] as? String else { throw DecodeError.invalid }
        let visit = object["visit"] as? Int
        switch type {
        case "set":
            guard let slot = object["slot"] as? Int, (0...2).contains(slot), visit != nil,
                  let label = object["segment"] as? String,
                  let segment = Segment(detectorLabel: label) else { throw DecodeError.invalid }
            kind = .set(slot: slot, segment: segment)
        case "next":
            guard visit != nil else { throw DecodeError.invalid }
            kind = .next
        case "undo": kind = .undo
        case "rematch": kind = .rematch
        case "report": kind = .report
        default: throw DecodeError.invalid
        }
        self.leg = leg
        self.visit = visit
    }
}

extension GameSession {
    /// The game as the web scoreboard sees it.
    var scoreboardSnapshot: ScoreboardSnapshot {
        var snapshot = ScoreboardSnapshot(match: match, leg: legID.uuidString, visitNumber: currentVisitNumber, board: boardStatus)
        snapshot.game?.report = lastReport.map {
            .init(id: $0.id.uuidString, message: $0.message, failed: $0.failed)
        }
        return snapshot
    }

    /// Applies a change from the web scoreboard with the same rules as the buttons on the phone.
    func apply(_ action: ScoreboardAction) {
        guard action.leg == legID.uuidString else { return }   // meant for an earlier game or leg
        switch action.kind {
        case let .set(slot, segment):
            guard let visit = action.visit else { return }
            note("web: set dart \(slot + 1) to \(segment.label)")
            set(slot: slot, ofVisit: visit, to: segment)
        case .next:
            guard action.visit == currentVisitNumber else { return }   // a repeated click
            note("web: next")
            next()
        case .undo:
            note("web: undo")
            undo()
        case .rematch:
            if match.isOver { rematch() }
        case .report:
            reportMistake(from: "web")
        }
    }
}
