import Foundation

/// Standard board dimensions in `BoardPoint` units (outer edge of the double ring = 1).
///
/// One definition for scoring, drawing and detection. It is the geometry the RF-DETR model
/// was evaluated with (`~/DartSynthetic/public_check/eval_public.py`): radii in millimetres
/// on a 451 mm board, the bull and outer bull measured to the outside of their wires.
enum BoardGeometry {
    /// Radius of the outer edge of the double ring.
    static let doubleOuterMM = 170.0
    /// Side of the square board face the detector works in (the board's outer edge is 225.5 mm).
    static let boardSizeMM = 451.0

    static let bullRadius = (6.35 + 0.8) / doubleOuterMM
    static let outerBullRadius = (15.9 + 0.8) / doubleOuterMM
    static let trebleInner = 97.4 / doubleOuterMM
    static let trebleOuter = 107.4 / doubleOuterMM
    static let doubleInner = 160.0 / doubleOuterMM
    static let doubleOuter = 1.0
    /// Outer edge of the number ring, for drawing.
    static let numberRing = 1.18

    /// Ring boundaries from the centre out, in `BoardPoint` units.
    static let ringRadii = [bullRadius, outerBullRadius, trebleInner, trebleOuter, doubleInner, doubleOuter]

    /// Angle of a number's bed centre in degrees, clockwise from the top.
    static func angle(of number: Int) -> Double {
        Double(Segment.boardOrder.firstIndex(of: number) ?? 0) * 18
    }

    /// Scores a point on the board face.
    static func segment(at point: BoardPoint) -> Segment {
        let r = point.radius
        if r <= bullRadius { return .bull }
        if r <= outerBullRadius { return .outerBull }
        if r > doubleOuter { return .miss }
        // Clockwise from the top, with y pointing down.
        var degrees = atan2(point.x, -point.y) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let index = Int(((degrees + 9) / 18).rounded(.down)) % 20
        let number = Segment.boardOrder[index]
        if r <= trebleInner { return .single(number) }
        if r <= trebleOuter { return .triple(number) }
        if r <= doubleInner { return .single(number) }
        return .double(number)
    }

    /// Distance in millimetres from a point to the nearest wire that changes its score
    /// (a ring or, outside the outer bull, a sector line).
    static func distanceToNearestWireMM(_ point: BoardPoint) -> Double {
        let r = point.radius
        var nearest = ringRadii.map { abs(r - $0) }.min()! * doubleOuterMM
        if r > outerBullRadius && r <= doubleOuter {
            var degrees = atan2(point.x, -point.y) * 180 / .pi
            if degrees < 0 { degrees += 360 }
            // Sector lines sit at 9°, 27°, ... ; distance to the nearest one along the arc's chord.
            let offset = (degrees + 9).truncatingRemainder(dividingBy: 18)
            let toLine = min(offset, 18 - offset) * .pi / 180
            nearest = min(nearest, r * sin(toLine) * doubleOuterMM)
        }
        return nearest
    }

    /// A point inside the given bed, `spread` 0...1 moving it around within the bed.
    static func point(in segment: Segment, angleOffset: Double = 0, radialOffset: Double = 0) -> BoardPoint? {
        let r: Double
        var degrees = 0.0
        switch segment {
        case .miss: return nil
        case .bull: return BoardPoint(x: bullRadius * 0.4 * angleOffset, y: bullRadius * 0.4 * radialOffset)
        case .outerBull:
            r = (bullRadius + outerBullRadius) / 2
            degrees = 360 * angleOffset
        case .single(let n):
            r = (outerBullRadius + trebleInner) / 2 + radialOffset * 0.15
            degrees = angle(of: n) + angleOffset * 7
        case .triple(let n):
            r = (trebleInner + trebleOuter) / 2 + radialOffset * 0.015
            degrees = angle(of: n) + angleOffset * 7
        case .double(let n):
            r = (doubleInner + doubleOuter) / 2 + radialOffset * 0.015
            degrees = angle(of: n) + angleOffset * 7
        }
        let radians = degrees * .pi / 180
        return BoardPoint(x: r * sin(radians), y: -r * cos(radians))
    }
}

extension BoardPoint {
    /// From millimetres relative to the board centre (x right, y down).
    init(millimetres p: SIMD2<Double>) {
        self.init(x: p.x / BoardGeometry.doubleOuterMM, y: p.y / BoardGeometry.doubleOuterMM)
    }

    /// Millimetres relative to the board centre (x right, y down).
    var millimetres: SIMD2<Double> { SIMD2(x, y) * BoardGeometry.doubleOuterMM }
}
