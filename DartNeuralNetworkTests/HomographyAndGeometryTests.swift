import XCTest
import simd
@testable import DartNeuralNetwork

final class HomographyTests: XCTestCase {
    /// A perspective view of the board: board millimetres → image pixels.
    static let camera = Homography(rows: [2.1, 0.25, 540, -0.15, 1.8, 610, 0.0004, -0.0002, 1])

    private func points(_ n: Int, seed: UInt64 = 1) -> [SIMD2<Double>] {
        var rng = SeededRandom(seed: seed)
        return (0..<n).map { _ in SIMD2(rng.uniform(-200, 200), rng.uniform(-200, 200)) }
    }

    func testExactFitRecoversKnownTransform() throws {
        let board = BoardCalibration.targetsMM
        let image = board.map { Self.camera.apply($0)! }
        let fit = try XCTUnwrap(Homography.fit(from: image, to: board))
        for p in points(50) {
            let pixel = Self.camera.apply(p)!
            XCTAssertLessThan(simd_distance(fit.apply(pixel)!, p), 1e-6)
        }
    }

    func testFourPointsAreEnough() throws {
        let board = Array(BoardCalibration.targetsMM.prefix(4))
        let fit = try XCTUnwrap(Homography.fit(from: board.map { Self.camera.apply($0)! }, to: board))
        let centre = fit.apply(Self.camera.apply(.zero)!)!
        XCTAssertLessThan(simd_length(centre), 1e-6)
    }

    func testDegeneratePointsGiveNil() {
        let line = (0..<5).map { SIMD2(Double($0) * 10, Double($0) * 5) }
        XCTAssertNil(Homography.fit(from: line, to: line))
        XCTAssertNil(Homography.robustFit(from: Array(line.prefix(3)), to: Array(line.prefix(3)), threshold: 6))
    }

    func testInverseRoundTrips() throws {
        let inverse = try XCTUnwrap(Self.camera.inverse)
        for p in points(20) {
            XCTAssertLessThan(simd_distance(inverse.apply(Self.camera.apply(p)!)!, p), 1e-9)
        }
    }

    func testRobustFitRejectsOutliers() throws {
        let board = BoardCalibration.targetsMM
        var rng = SeededRandom(seed: 3)
        var image = board.map { Self.camera.apply($0)! + SIMD2(rng.gaussian() * 0.6, rng.gaussian() * 0.6) }
        // Three points detected far away (a calibration class confused with another spot).
        image[2] += SIMD2(80, -40)
        image[7] += SIMD2(-60, 90)
        image[10] += SIMD2(35, 35)
        let fit = try XCTUnwrap(Homography.robustFit(from: image, to: board, threshold: 6))
        XCTAssertEqual(fit.inliers, (0..<12).map { ![2, 7, 10].contains($0) })
        XCTAssertLessThan(fit.rmsError, 2)
        // The board centre lands within a millimetre despite the outliers.
        XCTAssertLessThan(simd_length(fit.homography.apply(Self.camera.apply(.zero)!)!), 1)
    }

    func testRobustFitWithNoiseIsCloseToTruth() throws {
        let board = BoardCalibration.targetsMM
        var rng = SeededRandom(seed: 9)
        let image = board.map { Self.camera.apply($0)! + SIMD2(rng.gaussian(), rng.gaussian()) }
        let fit = try XCTUnwrap(Homography.robustFit(from: image, to: board, threshold: 6))
        XCTAssertEqual(fit.inlierCount, 12)
        for p in points(30, seed: 4) where simd_length(p) < 170 {
            XCTAssertLessThan(simd_distance(fit.homography.apply(Self.camera.apply(p)!)!, p), 1.5)
        }
    }
}

extension HomographyTests {
    /// Review finding: when refitting on the winning sample's inliers loses one, the winning
    /// transform is kept instead of returning nil. Searches noisy views for a case where an
    /// exhaustive 4-point search finds a consensus; `robustFit` must find one there too.
    func testRobustFitKeepsTheConsensusWhenTheRefitLosesAnInlier() {
        let board = BoardCalibration.targetsMM
        var rng = SeededRandom(seed: 41)
        func cross(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ r: SIMD2<Double>) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        var noisyViews = 0
        for trial in 0..<120 {
            let image = board.map { Self.camera.apply($0)! + SIMD2(rng.gaussian(), rng.gaussian()) * 10 }
            if Homography.robustFit(from: image, to: board, threshold: 6) != nil { continue }
            noisyViews += 1
            var best = 0
            for a in 0..<9 { for b in (a + 1)..<10 { for c in (b + 1)..<11 { for d in (c + 1)..<12 {
                let triangles = [(a, b, c), (a, b, d), (a, c, d), (b, c, d)]
                guard triangles.allSatisfy({ u, v, w in
                    let cs = cross(image[u], image[v], image[w]), ct = cross(board[u], board[v], board[w])
                    return abs(cs) >= 1e-9 && abs(ct) >= 1e-12 && (cs > 0) == (ct > 0)
                }) else { continue }
                let indices = [a, b, c, d]
                guard let h = Homography.fit(from: indices.map { image[$0] }, to: indices.map { board[$0] }) else { continue }
                let count = (0..<12).filter { i in h.apply(image[i]).map { simd_distance($0, board[i]) <= 6 } ?? false }.count
                best = max(best, count)
            } } } }
            XCTAssertLessThan(best, 4, "trial \(trial): a consensus of \(best) points exists but robustFit returned nil")
        }
        print("RESULT robustFit returned nil on \(noisyViews) of 120 noisy views, none with a consensus")
    }
}

final class ScoringGeometryTests: XCTestCase {
    /// The reference definition from the evaluation (board units: 451 mm square, centre 0.5).
    private func reference(_ p: SIMD2<Double>) -> Segment {
        let radii = [0, 6.35 + 0.8, 15.9 + 0.8, 97.4, 107.4, 160.0, 170.0].map { $0 / 451 }
        let order = [20, 1, 18, 4, 13, 6, 10, 15, 2, 17, 3, 19, 7, 16, 8, 11, 14, 9, 12, 5]
        let dx = p.x - 0.5, dy = p.y - 0.5, r = hypot(dx, dy)
        var angle = atan2(dx, -dy) * 180 / .pi
        angle = angle.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        let n = order[Int(((angle + 9) / 18).rounded(.down)) % 20]
        if r <= radii[1] { return .bull }
        if r <= radii[2] { return .outerBull }
        if r <= radii[3] { return .single(n) }
        if r <= radii[4] { return .triple(n) }
        if r <= radii[5] { return .single(n) }
        if r <= radii[6] { return .double(n) }
        return .miss
    }

    func testMatchesReferenceDefinitionEverywhere() {
        var rng = SeededRandom(seed: 11)
        for _ in 0..<20_000 {
            let unit = SIMD2(rng.uniform(0.05, 0.95), rng.uniform(0.05, 0.95))
            let mm = (unit - 0.5) * 451
            XCTAssertEqual(BoardGeometry.segment(at: BoardPoint(millimetres: mm)), reference(unit), "\(unit)")
        }
    }

    func testRingEdges() {
        func at(_ radiusMM: Double, degrees: Double = 0) -> Segment {
            let a = degrees * .pi / 180
            return BoardGeometry.segment(at: BoardPoint(millimetres: SIMD2(sin(a), -cos(a)) * radiusMM))
        }
        XCTAssertEqual(at(7.1), .bull)
        XCTAssertEqual(at(7.2), .outerBull)
        XCTAssertEqual(at(16.6), .outerBull)
        XCTAssertEqual(at(16.8), .single(20))
        XCTAssertEqual(at(97.3), .single(20))
        XCTAssertEqual(at(97.5), .triple(20))
        XCTAssertEqual(at(107.3), .triple(20))
        XCTAssertEqual(at(107.5), .single(20))
        XCTAssertEqual(at(159.9), .single(20))
        XCTAssertEqual(at(160.1), .double(20))
        XCTAssertEqual(at(169.9), .double(20))
        XCTAssertEqual(at(170.1), .miss)
        XCTAssertEqual(at(120, degrees: 8.9), .single(20))
        XCTAssertEqual(at(120, degrees: 9.1), .single(1))
        XCTAssertEqual(at(120, degrees: -9.1), .single(5))
    }

    func testCalibrationTargetsSitOnTheDoubleWire() {
        XCTAssertEqual(BoardCalibration.targetsMM.count, 12)
        for (i, p) in BoardCalibration.targetsMM.enumerated() {
            XCTAssertEqual(simd_length(p), 170, accuracy: 1e-9)
            // In board units: (0.5 + 170/451 sin a, 0.5 - 170/451 cos a).
            let a = BoardCalibration.angles[i] * .pi / 180
            let unit = p / 451 + 0.5
            XCTAssertEqual(unit.x, 0.5 + 170 / 451 * sin(a), accuracy: 1e-12)
            XCTAssertEqual(unit.y, 0.5 - 170 / 451 * cos(a), accuracy: 1e-12)
        }
        // Class 0 sits on the wire between 5 and 20 (−9°).
        XCTAssertLessThan(BoardCalibration.targetsMM[0].x, 0)
    }

    func testDistanceToWire() {
        XCTAssertEqual(BoardGeometry.distanceToNearestWireMM(BoardPoint(millimetres: SIMD2(0, -102.4))), 5, accuracy: 1e-9)
        let a = 8.0 * .pi / 180
        let nearLine = BoardPoint(millimetres: SIMD2(sin(a), -cos(a)) * 130)
        XCTAssertEqual(BoardGeometry.distanceToNearestWireMM(nearLine), 130 * sin(.pi / 180), accuracy: 1e-6)
    }
}

/// Deterministic random numbers for tests.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }

    mutating func gaussian() -> Double {
        let u = max(next(), 1e-12), v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
