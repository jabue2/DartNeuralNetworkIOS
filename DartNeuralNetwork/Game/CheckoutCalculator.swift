import Foundation

/// Suggests a finishing route for a remaining score.
///
/// Every legal route is enumerated once per rule set and the cheapest per score is kept.
/// Fewer darts always win; among equal dart counts the cost prefers single setups,
/// then high trebles (T20 first), and finishing doubles that split well (D20, D16, ...).
enum CheckoutCalculator {

    static func suggestion(for remaining: Int, dartsLeft: Int, doubleOut: Bool) -> [Segment]? {
        guard remaining > 0, dartsLeft > 0 else { return nil }
        let table = doubleOut ? doubleOutTable : straightOutTable
        for darts in 1...min(3, dartsLeft) {
            if let route = table[darts - 1][remaining] { return route }
        }
        return nil
    }

    // MARK: - Tables

    private static let doubleOutTable = buildTable(doubleOut: true)
    private static let straightOutTable = buildTable(doubleOut: false)

    /// table[dartCount - 1][score] = best route using exactly that many darts.
    private static func buildTable(doubleOut: Bool) -> [[Int: [Segment]]] {
        let setups = Segment.allScoring
        let finishers = doubleOut ? setups.filter(\.isDouble) : setups
        var best: [[Int: (cost: Double, route: [Segment])]] = [[:], [:], [:]]

        func offer(_ route: [Segment]) {
            let total = route.reduce(0) { $0 + $1.points }
            let slot = route.count - 1
            let cost = route.dropLast().reduce(0) { $0 + setupCost($1) } + finishCost(route.last!, doubleOut: doubleOut)
            if let current = best[slot][total], current.cost <= cost { return }
            best[slot][total] = (cost, route)
        }

        for finish in finishers {
            offer([finish])
            for first in setups {
                offer([first, finish])
                for second in setups where order(first, second) {
                    offer([first, second, finish])
                }
            }
        }
        return best.map { $0.mapValues(\.route) }
    }

    /// Keeps one ordering of two setup darts: higher score first, trebles before others on ties.
    private static func order(_ a: Segment, _ b: Segment) -> Bool {
        if a.points != b.points { return a.points > b.points }
        return a.multiplier >= b.multiplier
    }

    private static func setupCost(_ segment: Segment) -> Double {
        switch segment {
        case .single: return 0
        case .triple(let n): return 1.0 + Double(20 - n) * 0.1
        case .outerBull: return 1.6
        case .bull, .double: return 2.5
        case .miss: return 10
        }
    }

    /// Preferred finishing doubles: ones that still leave a double after a single miss.
    private static let doublePreference: [Int: Double] = [
        20: 0, 16: 0.05, 18: 0.2, 12: 0.25, 10: 0.25, 8: 0.3, 14: 0.35,
        6: 0.4, 4: 0.4, 2: 0.5, 19: 0.5, 17: 0.5, 15: 0.5, 13: 0.5, 11: 0.5,
        9: 0.6, 7: 0.6, 5: 0.6, 3: 0.6, 1: 0.8,
    ]

    private static func finishCost(_ segment: Segment, doubleOut: Bool) -> Double {
        guard doubleOut else { return setupCost(segment) }
        switch segment {
        case .double(let n): return doublePreference[n] ?? 0.7
        case .bull: return 0.9
        default: return 10
        }
    }
}
