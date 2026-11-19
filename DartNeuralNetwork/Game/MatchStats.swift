import Foundation

struct PlayerStats: Equatable {
    var pointsScored = 0
    var dartsThrown = 0
    var bestVisit = 0
    var visits = 0
    var oneEighties = 0
    /// Score of the finishing visit, if this player checked out.
    var checkout: Int?
    /// Darts thrown while a one-dart finish was on (double-out only).
    var dartsAtDouble = 0

    /// Points per three darts. Busts count as three darts scoring nothing.
    var threeDartAverage: Double {
        dartsThrown == 0 ? 0 : Double(pointsScored) / Double(dartsThrown) * 3
    }

    /// Share of darts at a double that won the leg. Nil when no dart was thrown at a double.
    var checkoutRate: Double? {
        guard dartsAtDouble > 0 else { return nil }
        return Double(checkout == nil ? 0 : 1) / Double(dartsAtDouble)
    }
}

extension X01Match {
    func stats(for player: Int) -> PlayerStats {
        var stats = PlayerStats()
        for visit in visits where visit.playerIndex == player {
            let evaluation = X01.evaluate(visit, rules: rules)
            stats.visits += 1
            stats.pointsScored += evaluation.scored

            switch evaluation.outcome {
            case .checkout:
                stats.dartsThrown += (evaluation.endIndex ?? 0) + 1
                stats.checkout = visit.startRemaining
            case .open:
                stats.dartsThrown += visit.darts.count
            case .scored, .bust:
                stats.dartsThrown += 3
            }
            if evaluation.outcome != .bust {
                stats.bestVisit = max(stats.bestVisit, evaluation.scored)
                if evaluation.scored == 180 { stats.oneEighties += 1 }
            }

            if rules.doubleOut {
                var remaining = visit.startRemaining
                let counted = evaluation.endIndex.map { visit.darts.prefix($0 + 1) } ?? visit.darts[...]
                for dart in counted {
                    if X01.isOneDartFinish(remaining, doubleOut: true) { stats.dartsAtDouble += 1 }
                    remaining -= dart.segment.points
                }
            }
        }
        return stats
    }
}
