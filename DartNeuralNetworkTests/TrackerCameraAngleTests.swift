import XCTest
import simd
@testable import DartNeuralNetwork

/// A pinhole camera looking at the board centre from `position` (board millimetres, x right,
/// y down, z < 0 in front of the board), principal point at the image centre.
struct PinholeCamera {
    var name: String
    var position: SIMD3<Double>
    var imageSize = CGSize(width: 1080, height: 1920)
    /// Focal length per pixel of the long side; 0.70 is a phone main camera, about 71 degrees (the
    /// tracker's default when it is not told the field of view).
    var focalRatio = 0.70
    var focalPixels: Double { focalRatio * Double(max(imageSize.width, imageSize.height)) }

    func pixel(_ p: SIMD3<Double>) -> SIMD2<Double> {
        let forward = simd_normalize(-position)
        let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), forward))
        let down = simd_cross(forward, right)
        let d = p - position
        let depth = simd_dot(d, forward)
        return SIMD2(focalPixels * simd_dot(d, right) / depth + Double(imageSize.width) / 2,
                     focalPixels * simd_dot(d, down) / depth + Double(imageSize.height) / 2)
    }

    /// Where a point `height` millimetres up a dart at `tip` (leaning by `lean` per millimetre)
    /// lands on the board plane, seen from this camera.
    func boardMap(_ tip: SIMD2<Double>, height: Double, lean: SIMD2<Double>) -> SIMD2<Double> {
        let p = SIMD3(tip.x + height * lean.x, tip.y + height * lean.y, -height)
        let s = position.z / (position.z - p.z)   // along the ray from the camera to the board plane
        let hit = position + (p - position) * s
        return SIMD2(hit.x, hit.y)
    }

    var footMM: SIMD2<Double> { SIMD2(position.x, position.y) }

    /// Straight in front, the user's mount on 2026-11-18 (about 42 degrees off, below left; from
    /// their board lock), from above, steep from the right, and from the left.
    static let poses: [PinholeCamera] = [
        PinholeCamera(name: "frontal", position: SIMD3(0, 0, -1800)),
        PinholeCamera(name: "user 42° below left", position: SIMD3(-447, 746, -996)),
        PinholeCamera(name: "45° above", position: SIMD3(0, -1100, -1100)),
        PinholeCamera(name: "60° right", position: SIMD3(1300, 0, -750)),
        PinholeCamera(name: "30° left", position: SIMD3(-800, -150, -1400)),
    ]
}

/// The same-landing rules from several camera angles: a dart's own barrel and flight never score
/// as a second dart, and real second darts still do.
final class TrackerCameraAngleTests: XCTestCase {
    struct Point { var tip: SIMD2<Double>; var height = 0.0; var confidence: Double }

    private var camera = PinholeCamera.poses[0]
    private var tracker = MultiFrameTracker(ignoresDartsAtStart: false)
    private var events: [DetectionEvent] = []
    private var rng = SeededRandom(seed: 11)
    private let lean = SIMD2(0.08, 0.12)

    private var darts: [DetectedDart] {
        events.compactMap { if case .dartDetected(let d) = $0 { return d } else { return nil } }
    }

    private func start(_ pose: PinholeCamera) {
        camera = pose
        tracker = MultiFrameTracker(ignoresDartsAtStart: false)
        events = []
        rng = SeededRandom(seed: 11)
        run(DetectorTuning.lockFramesNeeded + 2 + DetectorTuning.arrivalClearFrames)
        XCTAssertTrue(tracker.isLocked, pose.name)
    }

    private func run(_ count: Int, _ points: [Point] = []) {
        for _ in 0..<count {
            var detections = BoardCalibration.targetsMM.enumerated().map { c, mm in
                ModelDetection(classIndex: c, point: noisy(camera.pixel(SIMD3(mm.x, mm.y, 0))), confidence: 0.85)
            }
            for p in points {
                let q = SIMD3(p.tip.x + p.height * lean.x, p.tip.y + p.height * lean.y, -p.height)
                detections.append(ModelDetection(classIndex: RFDetrDecoder.dartClass, point: noisy(camera.pixel(q)),
                                                 confidence: p.confidence))
            }
            events += tracker.process(FrameObservation(imageSize: camera.imageSize, detections: detections))
        }
    }

    private func noisy(_ p: SIMD2<Double>) -> SIMD2<Double> { p + SIMD2(rng.gaussian(), rng.gaussian()) * 0.4 }

    private func segment(_ mm: SIMD2<Double>) -> Segment { BoardGeometry.segment(at: BoardPoint(millimetres: mm)) }

    /// A tip on the camera's side of the board, away from wires and from `avoiding`, whose point
    /// `height` up the dart still lands inside the scoring area (else the tracker would ignore it
    /// anyway, and the test would test nothing).
    private func tipFacingCamera(_ pose: PinholeCamera, height: Double, avoiding: [SIMD2<Double>] = [],
                                 bodyAtLeast: Double = 0) -> SIMD2<Double> {
        let toward = simd_length(pose.footMM) < 1 ? SIMD2(0.0, -1) : simd_normalize(pose.footMM)
        let side = SIMD2(-toward.y, toward.x)
        for r in stride(from: 150.0, through: -150, by: -5) {
            for offset in [0.0, 15, -15, 30, -30] {
                let tip = toward * r + side * offset
                let body = pose.boardMap(tip, height: height, lean: lean)
                guard simd_length(tip) < 155, simd_length(body) < 155, simd_distance(body, tip) >= bodyAtLeast,
                      BoardGeometry.distanceToNearestWireMM(BoardPoint(millimetres: tip)) > 3,
                      avoiding.allSatisfy({ simd_distance($0, tip) > 40 && simd_distance($0, body) > 40 }) else { continue }
                return tip
            }
        }
        XCTFail("no tip for \(pose.name)")
        return SIMD2(0, -40)
    }

    /// Case A of the phone game (2026-11-18): the flight end of the second dart, in the frame it
    /// landed, held at about 0.5. From the user's camera it landed 103 mm from the tip.
    func testFlightEndOfADartThatJustLandedIsPartOfItAtEveryAngle() {
        let first = SIMD2(50.0, -101)
        for pose in PinholeCamera.poses {
            start(pose)
            let user = pose.name.hasPrefix("user")
            let second = tipFacingCamera(pose, height: 110, avoiding: [first], bodyAtLeast: user ? 100 : 0)
            if user {
                XCTAssertGreaterThan(simd_distance(pose.boardMap(second, height: 110, lean: lean), second), 100)
            }
            let flight = Point(tip: second, height: 110, confidence: 0.5)
            run(25, [Point(tip: first, confidence: 0.8)])
            run(25, [Point(tip: first, confidence: 0.8), Point(tip: second, confidence: 0.85), flight])
            XCTAssertEqual(darts.map(\.segment), [segment(first), segment(second)], pose.name)
        }
    }

    /// A frame cluttered by noise just before a dart lands neither counts as a clear view nor
    /// starts the count over: its flight end is still part of it.
    func testAClutteredFrameJustBeforeALandingKeepsTheFlightWithItsDart() {
        let first = SIMD2(50.0, -101)
        let noise = (0..<12).map { Point(tip: SIMD2(-130 + 22 * Double($0), 120), confidence: 0.1) }
        for pose in PinholeCamera.poses {
            start(pose)
            let second = tipFacingCamera(pose, height: 110, avoiding: [first])
            run(25, [Point(tip: first, confidence: 0.8)])
            run(1, [Point(tip: first, confidence: 0.8)] + noise)
            run(25, [Point(tip: first, confidence: 0.8), Point(tip: second, confidence: 0.85),
                     Point(tip: second, height: 110, confidence: 0.5)])
            XCTAssertEqual(darts.map(\.segment), [segment(first), segment(second)], pose.name)
        }
    }

    /// Case B of the phone game: a faint twin 13 mm from a tip, starting 4 usable frames after it.
    func testFaintTwinStartingAFewFramesAfterItsDartIsPartOfItAtEveryAngle() {
        let tip = SIMD2(-71.0, -107), twin = tip + SIMD2(-6, 12)
        for pose in PinholeCamera.poses {
            start(pose)
            run(4, [Point(tip: tip, confidence: 0.7)])
            for i in 0..<30 {
                run(1, [Point(tip: tip, confidence: 0.6), Point(tip: twin, confidence: i % 2 == 0 ? 0.45 : 0.25)])
            }
            XCTAssertEqual(darts.map(\.segment), [segment(tip)], pose.name)
        }
    }

    /// Phone, 2026-11-18: a twin 10 mm from a tip, seen once as the dart confirmed, then back at
    /// 0.5-0.7 for seconds. It is that dart, not a stacked second one.
    func testATwinSeenOnceThenBackStrongIsPartOfItsDart() {
        let tip = SIMD2(-14.0, -56), twin = tip + SIMD2(8, -6)
        for pose in PinholeCamera.poses {
            start(pose)
            run(1, [Point(tip: tip, confidence: 0.82)])
            run(1, [Point(tip: tip, confidence: 0.83), Point(tip: twin, confidence: 0.56)])
            run(2, [Point(tip: tip, confidence: 0.83)])   // back 4 frames after the dart appeared
            for i in 0..<20 {
                run(1, [Point(tip: tip, confidence: 0.82), Point(tip: twin, confidence: [0.61, 0.66, 0.54, 0.69][i % 4])])
            }
            XCTAssertEqual(darts.map(\.segment), [segment(tip)], pose.name)
        }
    }

    /// The tracker assumes a typical phone lens when it is not told the field of view. A wider or
    /// narrower lens moves its camera estimate, but the flight end is still part of its dart.
    func testAnotherLensStillKeepsTheFlightEndWithItsDart() {
        let first = SIMD2(50.0, -101)
        for ratio in [0.55, 0.9] {
            var pose = PinholeCamera.poses[1]
            pose.focalRatio = ratio
            start(pose)
            let second = tipFacingCamera(pose, height: 110, avoiding: [first])
            XCTAssertNotNil(tracker.cameraPosition, "focal \(ratio)")
            run(25, [Point(tip: first, confidence: 0.8)])
            run(25, [Point(tip: first, confidence: 0.8), Point(tip: second, confidence: 0.85),
                     Point(tip: second, height: 110, confidence: 0.5)])
            XCTAssertEqual(darts.map(\.segment), [segment(first), segment(second)], "focal \(ratio)")
        }
    }

    /// The flight confirms before the tip: its tip track starts two frames later. Still one dart.
    func testAFlightThatConfirmsBeforeItsTipStillMakesOneDart() {
        let tip = SIMD2(-35.0, 20)
        for pose in PinholeCamera.poses {
            start(pose)
            run(2, [Point(tip: tip, height: 90, confidence: 0.7)])
            run(30, [Point(tip: tip, confidence: 0.6), Point(tip: tip, height: 90, confidence: 0.7)])
            XCTAssertEqual(darts.count, 1, pose.name)
        }
    }

    /// A faint tip that confirms well after its flight: one dart.
    func testAFaintTipConfirmingAfterItsFlightStillMakesOneDart() {
        let tip = SIMD2(-35.0, 20)
        for pose in PinholeCamera.poses {
            start(pose)
            for i in 0..<30 {
                run(1, [Point(tip: tip, confidence: i == 11 ? 0.31 : 0.08), Point(tip: tip, height: 80, confidence: 0.6)])
            }
            XCTAssertEqual(darts.count, 1, pose.name)
        }
    }

    /// The twin window is five frames: a faint point 15 mm from a dart (outside the stacked zone)
    /// that starts five frames after it is that dart; one starting six frames after is a dart.
    func testTheTwinWindowEndsAfterFiveFrames() {
        let first = SIMD2(30.0, 60), second = first + SIMD2(15, 0)
        for (gap, expected) in [(5, 1), (6, 2)] {
            for pose in PinholeCamera.poses {
                start(pose)
                run(gap, [Point(tip: first, confidence: 0.8)])
                run(25, [Point(tip: first, confidence: 0.8), Point(tip: second, confidence: 0.55)])
                XCTAssertEqual(darts.count, expected, "\(pose.name), \(gap) frames")
            }
        }
    }

    /// A clutter between two throws: the board points seen during it keep the first dart's barrel
    /// recent, so a barrel point turning strong as the clutter ends is still that dart.
    func testABarrelPointSeenThroughClutterStaysPartOfItsDart() {
        let pose = PinholeCamera.poses[1]
        start(pose)
        let tip = tipFacingCamera(pose, height: 40)
        let barrel = Point(tip: tip, height: 40, confidence: 0.3)
        let noise = (0..<12).map { Point(tip: SIMD2(-130 + 22 * Double($0), 120), confidence: 0.1) }
        run(25, [Point(tip: tip, confidence: 0.8), barrel])
        run(4, [Point(tip: tip, confidence: 0.8), barrel] + noise)
        run(25, [Point(tip: tip, confidence: 0.8), Point(tip: tip, height: 40, confidence: 0.55)])
        XCTAssertEqual(darts.count, 1)
    }


    /// Three darts in the board, each seen with points up its barrel and flight: many detections,
    /// but all explained by the darts, so the third dart still scores (see `clutterEnterDarts`).
    func testDartsInTheBoardWithTheirBodiesDoNotHideTheThirdDart() {
        let tips = [SIMD2(-40.0, -60), SIMD2(0.0, -70), SIMD2(45.0, -40)]
        func body(_ tip: SIMD2<Double>) -> [Point] {
            [Point(tip: tip, confidence: 0.8), Point(tip: tip, height: 25, confidence: 0.3),
             Point(tip: tip, height: 60, confidence: 0.3), Point(tip: tip, height: 110, confidence: 0.3)]
        }
        for pose in PinholeCamera.poses where pose.name != "frontal" {
            start(pose)
            run(15, body(tips[0]))
            run(15, body(tips[0]) + body(tips[1]))
            run(25, body(tips[0]) + body(tips[1]) + body(tips[2]))
            XCTAssertEqual(darts.map(\.segment), tips.map(segment), pose.name)
        }
    }

    /// A real second dart behind the first (seen from the camera), half a second later, counts.
    func testASecondDartBehindTheFirstHalfASecondLaterCounts() {
        let first = SIMD2(-20.0, -40)
        for pose in PinholeCamera.poses {
            start(pose)
            let away = simd_normalize(first - pose.footMM)
            let second = first + away * 60
            run(5, [Point(tip: first, confidence: 0.8)])
            run(25, [Point(tip: first, confidence: 0.8), Point(tip: second, confidence: 0.8)])
            XCTAssertEqual(darts.map(\.segment), [segment(first), segment(second)], pose.name)
        }
    }

    /// A steady dart 15 mm from the first, a second or more later, counts (not a twin).
    func testADartBesideTheFirstASecondLaterCounts() {
        let first = SIMD2(30.0, 60), second = first + SIMD2(15, 0)
        for pose in PinholeCamera.poses {
            start(pose)
            run(12, [Point(tip: first, confidence: 0.8)])
            run(25, [Point(tip: first, confidence: 0.8), Point(tip: second, confidence: 0.8)])
            XCTAssertEqual(darts.map(\.segment), [segment(first), segment(second)], pose.name)
        }
    }

    /// Review Z6: the flight seen more strongly than the tip. One dart (which point is reported
    /// depends on which confirms first; the tracker does not hold a strong point back).
    func testFlightStrongerThanItsTipStillMakesOneDart() {
        for pose in PinholeCamera.poses where pose.name != "frontal" {
            start(pose)
            let tip = tipFacingCamera(pose, height: 80)
            XCTAssertGreaterThan(simd_distance(pose.boardMap(tip, height: 80, lean: lean), tip), 20)
            run(30, [Point(tip: tip, confidence: 0.35), Point(tip: tip, height: 80, confidence: 0.7)])
            XCTAssertEqual(darts.count, 1, pose.name)
        }
    }
}
