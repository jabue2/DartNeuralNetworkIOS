import CoreGraphics
import Foundation
import simd

/// Where the camera stands relative to the board, worked out from the board lock.
///
/// The tracker works on a flat map of the board in millimetres. A dart's tip lies on the board, so
/// it maps correctly; its barrel and flight stand out of the board, so the map puts them where the
/// camera's line of sight through them meets the board: behind the tip, seen from the camera. How
/// far behind depends on the camera's angle: nothing for a camera straight in front of the dart,
/// about the height for one 45 degrees off. Knowing the camera position turns that into geometry
/// (`bodyZoneContains`) instead of a radius tuned to one camera.
struct CameraPosition: Equatable {
    /// The point of the board plane straight below the camera (board millimetres, x right, y down).
    var footMM: SIMD2<Double>
    /// The camera's distance from the board plane.
    var distanceMM: Double

    typealias Tuning = DetectorTuning

    /// Pinhole camera with its principal point at the image centre and square pixels.
    /// - Parameters:
    ///   - imageFromBoard: board millimetres → image pixels.
    ///   - focalPixels: focal length in pixels of this image.
    /// Nil when the homography is not a plausible view of a flat board by such a camera (it would
    /// need a very different focal length, or puts the camera unreasonably close or far).
    init?(imageFromBoard g: Homography, imageSize: CGSize, focalPixels f: Double) {
        guard f > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let centre = simd_double3x3(rows: [SIMD3(1, 0, -Double(imageSize.width) / 2),
                                           SIMD3(0, 1, -Double(imageSize.height) / 2),
                                           SIMD3(0, 0, 1)])
        let inverseK = simd_double3x3(diagonal: SIMD3(1 / f, 1 / f, 1))
        let m = inverseK * centre * g.matrix   // columns: λ·r1, λ·r2, λ·t
        var r1 = m.columns.0, r2 = m.columns.1, t = m.columns.2
        let n1 = simd_length(r1), n2 = simd_length(r2)
        guard n1 > 0, n2 > 0, n1.isFinite, n2.isFinite else { return nil }
        // A real camera gives two orthogonal unit columns; a homography far from that is no view
        // this focal length can explain.
        let ratio = n1 / n2
        let cosine = simd_dot(r1, r2) / (n1 * n2)
        guard ratio >= 1 / Tuning.cameraColumnRatioLimit, ratio <= Tuning.cameraColumnRatioLimit,
              abs(cosine) <= Tuning.cameraColumnCosineLimit else { return nil }
        let scale = 2 / (n1 + n2)
        r1 *= scale; r2 *= scale; t *= scale
        if t.z < 0 { r1 = -r1; r2 = -r2; t = -t }   // the board is in front of the camera
        let x = simd_normalize(r1), y = simd_normalize(r2), z = simd_normalize(simd_cross(r1, r2))
        let rotation = simd_double3x3(columns: (x, y, z))   // nearly orthonormal (checked above)
        let camera = -(rotation.inverse * t)   // board coordinates; z points into the board
        let distance = -camera.z
        guard camera.x.isFinite, camera.y.isFinite, distance >= Tuning.cameraDistanceRangeMM.lowerBound,
              distance <= Tuning.cameraDistanceRangeMM.upperBound else { return nil }
        footMM = SIMD2(camera.x, camera.y)
        self.distanceMM = distance
    }

    init(footMM: SIMD2<Double>, distanceMM: Double) {
        self.footMM = footMM
        self.distanceMM = distanceMM
    }

    /// Focal length in pixels: from the camera's horizontal field of view (along the long side of
    /// the frame), or a typical phone main camera when unknown (old recordings).
    static func focalPixels(imageSize: CGSize, fieldOfViewDegrees: Double?) -> Double {
        let longSide = Double(max(imageSize.width, imageSize.height))
        guard let degrees = fieldOfViewDegrees, degrees > 1, degrees < 179 else {
            return Tuning.nominalFocalPerLongSide * longSide
        }
        return longSide / 2 / tan(degrees * .pi / 360)
    }

    /// Where a point `heightMM` above the board at `tip` appears on the board map.
    func projected(_ tip: SIMD2<Double>, heightMM: Double) -> SIMD2<Double> {
        tip + (tip - footMM) * (heightMM / (distanceMM - heightMM))
    }

    /// `p` may be a point on the body of a dart whose tip is at `tip`: near where some height on
    /// that dart appears, allowing for the dart leaning in the board (more the higher up; the lean
    /// is magnified on the board map like the height). Behind the tip as seen from the camera; a
    /// cone, not a disc, because parallax only pushes away from the camera.
    func bodyZoneContains(_ p: SIMD2<Double>, tip: SIMD2<Double>) -> Bool {
        let steps = Tuning.bodyZoneSamples
        for i in 0...steps {
            let height = Tuning.bodyMaxHeightMM * Double(i) / Double(steps)
            let magnification = distanceMM / (distanceMM - height)
            let allowance = Tuning.bodyZoneBaseMM + Tuning.bodyZoneLeanPerMM * height * magnification
            if simd_distance(p, projected(tip, heightMM: height)) <= allowance { return true }
        }
        return false
    }
}
