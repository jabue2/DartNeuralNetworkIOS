import CoreGraphics
import Foundation
import simd

/// Where the model's 12 calibration points sit on the board: on the outer double wire
/// (170 mm), at these angles clockwise from straight up, for classes 0...11.
enum BoardCalibration {
    static let angles: [Double] = [-9, 171, 261, 81, 27, 45, 117, 135, 207, 225, 297, 315]

    /// Targets in millimetres from the board centre (x right, y down).
    static let targetsMM: [SIMD2<Double>] = angles.map { degrees in
        let a = degrees * .pi / 180
        return SIMD2(BoardGeometry.doubleOuterMM * sin(a), -BoardGeometry.doubleOuterMM * cos(a))
    }

    struct Fit {
        /// Image pixels → board millimetres.
        var homography: Homography
        /// Classes used, and which of them fit (`inliers[i]` belongs to `classes[i]`).
        var classes: [Int]
        var inliers: [Bool]
        var rmsErrorMM: Double
        var inlierClasses: [Int] { zip(classes, inliers).filter(\.1).map(\.0) }
    }

    /// Robust homography from calibration points (class → pixel). Nil with fewer than four points
    /// or when no four of them agree.
    static func fit(_ points: [Int: SIMD2<Double>]) -> Fit? {
        let classes = points.keys.sorted()
        guard classes.count >= 4,
              let fit = Homography.robustFit(from: classes.map { points[$0]! }, to: classes.map { targetsMM[$0] },
                                             threshold: DetectorTuning.ransacThresholdMM)
        else { return nil }
        return Fit(homography: fit.homography, classes: classes, inliers: fit.inliers, rmsErrorMM: fit.rmsError)
    }
}

/// What the model saw in one frame, in pixels of the upright frame.
struct FrameObservation {
    var imageSize: CGSize
    /// Region the model looked at (the whole frame when not cropped).
    var crop: CGRect
    /// Merged detections at `DetectorTuning.decodeFloor` or more.
    var detections: [ModelDetection]

    init(imageSize: CGSize, crop: CGRect? = nil, detections: [ModelDetection]) {
        self.imageSize = imageSize
        self.crop = crop ?? CGRect(origin: .zero, size: imageSize)
        self.detections = detections
    }

    /// The most confident detection per calibration class at `calibrationConfidence` or more.
    var calibrationPoints: [Int: SIMD2<Double>] {
        var best: [Int: ModelDetection] = [:]
        for d in detections where !d.isDart && d.confidence >= DetectorTuning.calibrationConfidence {
            if (best[d.classIndex]?.confidence ?? 0) < d.confidence { best[d.classIndex] = d }
        }
        return best.mapValues(\.point)
    }

    func darts(minConfidence: Double) -> [ModelDetection] {
        detections.filter { $0.isDart && $0.confidence >= minConfidence }
    }
}

/// Scoring one image with no history: the single-frame path (and the replay test of it).
struct SingleImageResult {
    struct ScoredDart {
        var pixel: SIMD2<Double>
        var boardMM: SIMD2<Double>
        var segment: Segment
        var confidence: Double
    }

    var calibration: BoardCalibration.Fit?
    var darts: [ScoredDart]

    /// Single-frame reference rule: calibration points and darts at 0.25 or more.
    static let singleFrameDartConfidence = 0.25

    init(_ observation: FrameObservation, dartConfidence: Double = singleFrameDartConfidence) {
        calibration = BoardCalibration.fit(observation.calibrationPoints)
        guard let h = calibration?.homography else { darts = []; return }
        darts = observation.darts(minConfidence: dartConfidence).compactMap { d in
            guard let mm = h.apply(d.point) else { return nil }
            return ScoredDart(pixel: d.point, boardMM: mm, segment: BoardGeometry.segment(at: BoardPoint(millimetres: mm)),
                              confidence: d.confidence)
        }
    }
}
