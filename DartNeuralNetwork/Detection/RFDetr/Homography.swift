import Foundation
import simd

/// A plane-to-plane projective transform (3x3 matrix), here from image pixels to board millimetres.
///
/// Plain Swift so it runs in the simulator and in unit tests; replaces OpenCV's `findHomography`.
struct Homography: Equatable {
    /// Row-major entries; `matrix * (x, y, 1)`.
    var matrix: simd_double3x3

    init(matrix: simd_double3x3) { self.matrix = matrix }

    /// From nine row-major entries.
    init(rows h: [Double]) {
        precondition(h.count == 9)
        matrix = simd_double3x3(rows: [SIMD3(h[0], h[1], h[2]), SIMD3(h[3], h[4], h[5]), SIMD3(h[6], h[7], h[8])])
    }

    static let identity = Homography(matrix: matrix_identity_double3x3)

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double>? {
        let v = matrix * SIMD3(p.x, p.y, 1)
        guard abs(v.z) > 1e-12 else { return nil }
        return SIMD2(v.x / v.z, v.y / v.z)
    }

    var inverse: Homography? {
        guard abs(matrix.determinant) > 1e-18 else { return nil }
        return Homography(matrix: matrix.inverse)
    }

    /// `other` applied after `self`.
    func then(_ other: Homography) -> Homography { Homography(matrix: other.matrix * matrix) }

    // MARK: Fitting

    /// Least-squares DLT fit through four or more correspondences (Hartley-normalised).
    /// Nil when the points are degenerate.
    static func fit(from source: [SIMD2<Double>], to target: [SIMD2<Double>]) -> Homography? {
        precondition(source.count == target.count)
        guard source.count >= 4,
              let ts = normalisation(for: source), let td = normalisation(for: target),
              let tdInverse = td.inverse else { return nil }
        // Unknowns h0...h7 with h8 = 1. In normalised coordinates the source centroid sits at the
        // origin and maps to a finite point, so h8 = 1 is safe.
        var ata = [Double](repeating: 0, count: 64)
        var atb = [Double](repeating: 0, count: 8)
        for (s, t) in zip(source, target) {
            guard let p = ts.apply(s), let q = td.apply(t) else { return nil }
            let rows: [([Double], Double)] = [
                ([p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y], q.x),
                ([0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y], q.y),
            ]
            for (a, b) in rows {
                for i in 0..<8 {
                    atb[i] += a[i] * b
                    for j in 0..<8 { ata[i * 8 + j] += a[i] * a[j] }
                }
            }
        }
        guard let h = solve(ata, atb, n: 8) else { return nil }
        let normalised = Homography(rows: h + [1])
        let result = ts.then(normalised).then(tdInverse)
        let scale = result.matrix[2, 2]
        guard abs(scale) > 1e-15, result.matrix.determinant.isFinite else { return nil }
        return Homography(matrix: result.matrix * (1 / scale))
    }

    struct Fit {
        var homography: Homography
        /// One flag per input pair.
        var inliers: [Bool]
        /// Root mean square reprojection error of the inliers, in target units.
        var rmsError: Double
        var inlierCount: Int { inliers.filter { $0 }.count }
    }

    /// Robust fit: tries every 4-point subset (there are at most 495 for 12 points), keeps the one
    /// with the most points within `threshold` (target units), then refits on its inliers.
    /// Same idea as OpenCV's RANSAC, but exhaustive and deterministic for small inputs.
    static func robustFit(from source: [SIMD2<Double>], to target: [SIMD2<Double>], threshold: Double) -> Fit? {
        let n = source.count
        guard n >= 4, n == target.count else { return nil }
        var best: (homography: Homography, inliers: [Bool], count: Int, error: Double)?
        for subset in subsets(of: n, maxCount: 3000) {
            let s = subset.map { source[$0] }, t = subset.map { target[$0] }
            guard sameOrientation(s, t), let h = fit(from: s, to: t) else { continue }
            let (inliers, count, error) = score(h, source, target, threshold)
            if count < 4 { continue }
            if best == nil || count > best!.count || (count == best!.count && error < best!.error) {
                best = (h, inliers, count, error)
            }
        }
        guard let winner = best else { return nil }
        var chosen = (inliers: winner.inliers, count: winner.count, error: winner.error)
        // Refit on the inliers until the inlier set stops changing (at most a few rounds). A refit
        // that loses inliers is discarded; the last accepted transform (at worst the winning
        // minimal-sample one) is kept, so a valid consensus is never thrown away.
        var homography = winner.homography
        for _ in 0..<3 {
            let s = (0..<n).filter { chosen.inliers[$0] }
            guard let h = fit(from: s.map { source[$0] }, to: s.map { target[$0] }) else { break }
            let rescored = score(h, source, target, threshold)
            guard rescored.count >= chosen.count else { break }
            homography = h
            let changed = rescored.inliers != chosen.inliers
            chosen = rescored
            if !changed { break }
        }
        let rms = (chosen.error / Double(max(chosen.count, 1))).squareRoot()
        return Fit(homography: homography, inliers: chosen.inliers, rmsError: rms)
    }

    // MARK: Helpers

    /// Inlier flags, inlier count and sum of squared inlier errors.
    private static func score(_ h: Homography, _ source: [SIMD2<Double>], _ target: [SIMD2<Double>],
                              _ threshold: Double) -> (inliers: [Bool], count: Int, error: Double) {
        var flags = [Bool](repeating: false, count: source.count)
        var count = 0, error = 0.0
        for i in source.indices {
            guard let p = h.apply(source[i]) else { continue }
            let d2 = simd_distance_squared(p, target[i])
            if d2 <= threshold * threshold {
                flags[i] = true; count += 1; error += d2
            }
        }
        return (flags, count, error)
    }

    /// A minimal sample is only valid if every triangle keeps its orientation (no mirroring,
    /// no three collinear points), as in OpenCV's subset check.
    private static func sameOrientation(_ s: [SIMD2<Double>], _ t: [SIMD2<Double>]) -> Bool {
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let triangles = [(0, 1, 2), (0, 1, 3), (0, 2, 3), (1, 2, 3)]
        for (a, b, c) in triangles {
            let cs = cross(s[a], s[b], s[c]), ct = cross(t[a], t[b], t[c])
            if abs(cs) < 1e-9 || abs(ct) < 1e-12 || (cs > 0) != (ct > 0) { return false }
        }
        return true
    }

    /// All 4-element index subsets, or a fixed pseudo-random selection when there are too many.
    private static func subsets(of n: Int, maxCount: Int) -> [[Int]] {
        var all: [[Int]] = []
        let total = n * (n - 1) * (n - 2) * (n - 3) / 24
        if total <= maxCount {
            for a in 0..<n { for b in (a + 1)..<n { for c in (b + 1)..<n { for d in (c + 1)..<n {
                all.append([a, b, c, d])
            } } } }
            return all
        }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(n))
        }
        while all.count < maxCount {
            let pick = Set((0..<8).map { _ in next() })
            if pick.count >= 4 { all.append(Array(pick.prefix(4)).sorted()) }
        }
        return all
    }

    /// Similarity transform that moves the centroid to the origin and the mean distance to √2.
    private static func normalisation(for points: [SIMD2<Double>]) -> Homography? {
        let centroid = points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
        let meanDistance = points.map { simd_distance($0, centroid) }.reduce(0, +) / Double(points.count)
        guard meanDistance > 1e-12 else { return nil }
        let s = 2.0.squareRoot() / meanDistance
        return Homography(rows: [s, 0, -s * centroid.x, 0, s, -s * centroid.y, 0, 0, 1])
    }

    /// Gaussian elimination with partial pivoting for a small dense system.
    private static func solve(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        var m = a, v = b
        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<n where abs(m[row * n + col]) > abs(m[pivot * n + col]) { pivot = row }
            guard abs(m[pivot * n + col]) > 1e-12 else { return nil }
            if pivot != col {
                for k in 0..<n { m.swapAt(col * n + k, pivot * n + k) }
                v.swapAt(col, pivot)
            }
            for row in (col + 1)..<n {
                let f = m[row * n + col] / m[col * n + col]
                if f == 0 { continue }
                for k in col..<n { m[row * n + k] -= f * m[col * n + k] }
                v[row] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<n { sum -= m[row * n + k] * x[k] }
            x[row] = sum / m[row * n + row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }
}
