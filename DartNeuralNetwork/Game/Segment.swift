import Foundation

/// Where a dart landed, in scoring terms. No UI dependency.
enum Segment: Hashable, Codable {
    case miss
    case single(Int)
    case double(Int)
    case triple(Int)
    case outerBull
    case bull

    /// Numbers clockwise from the top of a standard board.
    static let boardOrder = [20, 1, 18, 4, 13, 6, 10, 15, 2, 17, 3, 19, 7, 16, 8, 11, 14, 9, 12, 5]

    var points: Int {
        switch self {
        case .miss: return 0
        case .single(let n): return n
        case .double(let n): return 2 * n
        case .triple(let n): return 3 * n
        case .outerBull: return 25
        case .bull: return 50
        }
    }

    /// Valid as the last dart of a double-out finish (doubles and the bull).
    var isDouble: Bool {
        switch self {
        case .double, .bull: return true
        default: return false
        }
    }

    /// The number of the bed (1...20), nil for bulls and misses.
    var number: Int? {
        switch self {
        case .single(let n), .double(let n), .triple(let n): return n
        default: return nil
        }
    }

    var multiplier: Int {
        switch self {
        case .miss: return 0
        case .single, .outerBull: return 1
        case .double, .bull: return 2
        case .triple: return 3
        }
    }

    /// Compact scoreboard label: "T20", "D16", "19", "25", "Bull", "Miss".
    var label: String {
        switch self {
        case .miss: return "Miss"
        case .single(let n): return "\(n)"
        case .double(let n): return "D\(n)"
        case .triple(let n): return "T\(n)"
        case .outerBull: return "25"
        case .bull: return "Bull"
        }
    }

    var isValid: Bool {
        if let n = number { return (1...20).contains(n) }
        return true
    }

    /// Every distinct way to score with one dart (62 segments, excluding miss).
    static let allScoring: [Segment] = {
        var all: [Segment] = []
        for n in 1...20 { all += [.single(n), .double(n), .triple(n)] }
        return all + [.outerBull, .bull]
    }()

    /// Parses labels produced by the detector and by older app versions:
    /// "T20", "D16", "S5", "DB", "SB", "miss", "0", "Bull", "Outer Bull", "25", "50".
    init?(detectorLabel raw: String) {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch label {
        case "", "0", "MISS", "M": self = .miss; return
        case "DB", "BULL", "50", "INNER BULL", "BULLSEYE": self = .bull; return
        case "SB", "OUTER BULL", "25": self = .outerBull; return
        default: break
        }
        let prefix = label.first!
        let digits = label.dropFirst().trimmingCharacters(in: .whitespaces)
        let segment: Segment
        if let n = Int(label) {
            segment = .single(n)
        } else if let n = Int(digits) {
            switch prefix {
            case "S": segment = .single(n)
            case "D": segment = .double(n)
            case "T": segment = .triple(n)
            default: return nil
            }
        } else {
            return nil
        }
        guard segment.isValid else { return nil }
        self = segment
    }
}
