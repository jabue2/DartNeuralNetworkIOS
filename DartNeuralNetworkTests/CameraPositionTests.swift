import XCTest
import simd
@testable import DartNeuralNetwork

/// `CameraPosition` from a board lock: where the camera stands, and where a dart's body appears.
final class CameraPositionTests: XCTestCase {
    /// The board seen by `camera`: board millimetres → image pixels.
    private func imageFromBoard(_ camera: PinholeCamera) -> Homography {
        let board = BoardCalibration.targetsMM
        return Homography.fit(from: board, to: board.map { camera.pixel(SIMD3($0.x, $0.y, 0)) })!
    }

    func testRecoversTheCameraFromItsBoardLockAtEveryAngle() throws {
        for camera in PinholeCamera.poses {
            let found = try XCTUnwrap(CameraPosition(imageFromBoard: imageFromBoard(camera), imageSize: camera.imageSize,
                                                     focalPixels: camera.focalPixels), camera.name)
            let estimate = SIMD3(found.footMM.x, found.footMM.y, -found.distanceMM)
            XCTAssertLessThan(simd_distance(estimate, camera.position), 0.05 * simd_length(camera.position), camera.name)
        }
    }

    /// Through the tracker: with the default focal length, then told the camera's real (wider) field
    /// of view, which moves the estimate onto the camera.
    func testTheTrackerFindsTheCameraFromItsLock() throws {
        var camera = PinholeCamera.poses[1]
        camera.focalRatio = 0.55
        var tracker = MultiFrameTracker(ignoresDartsAtStart: false)
        let detections = BoardCalibration.targetsMM.enumerated().map { c, mm in
            ModelDetection(classIndex: c, point: camera.pixel(SIMD3(mm.x, mm.y, 0)), confidence: 0.85)
        }
        for _ in 0..<(DetectorTuning.lockFramesNeeded + 2) {
            _ = tracker.process(FrameObservation(imageSize: camera.imageSize, detections: detections))
        }
        func error(_ found: CameraPosition) -> Double {
            simd_distance(SIMD3(found.footMM.x, found.footMM.y, -found.distanceMM), camera.position)
        }
        let nominal = try XCTUnwrap(tracker.cameraPosition)
        XCTAssertGreaterThan(error(nominal), 0.1 * simd_length(camera.position))   // the wrong lens
        let degrees = 2 * atan(Double(camera.imageSize.height) / 2 / camera.focalPixels) * 180 / .pi
        tracker.setCameraFieldOfView(degrees)
        let told = try XCTUnwrap(tracker.cameraPosition)
        XCTAssertLessThan(error(told), 0.05 * simd_length(camera.position))
    }

    /// No camera explains a sheared board: no position (the tracker then falls back to a disc).
    func testAnImplausibleLockGivesNoCamera() {
        let shear = Homography(rows: [1.2, 0.9, 540, 0, 1.2, 960, 0, 0, 1])
        XCTAssertNil(CameraPosition(imageFromBoard: shear, imageSize: CGSize(width: 1080, height: 1920), focalPixels: 1344))
    }

    /// A close, steep camera magnifies a leaning flight sideways on the board map as much as its
    /// height: the zone still holds it.
    func testTheBodyZoneHoldsALeaningFlightSeenFromCloseUp() {
        let pinhole = PinholeCamera(name: "close 60° left", position: SIMD3(-480, 0, -280))
        let camera = CameraPosition(footMM: pinhole.footMM, distanceMM: -pinhole.position.z)
        let tip = SIMD2(-60.0, -40)
        for lean in [SIMD2(0.0, 0.5), SIMD2(0.0, -0.5), SIMD2(0.35, 0.35)] {
            for height in [40.0, 90, 130] {
                let flight = pinhole.boardMap(tip, height: height, lean: lean)
                XCTAssertTrue(camera.bodyZoneContains(flight, tip: tip), "lean \(lean) height \(height)")
            }
        }
    }

    /// Parallax pushes a point up the dart away from the camera: the projection matches the pinhole
    /// camera, the zone holds the body and not the camera side of the tip.
    func testTheBodyZoneLiesBehindTheTipSeenFromTheCamera() {
        let pinhole = PinholeCamera.poses[1]
        let camera = CameraPosition(footMM: pinhole.footMM, distanceMM: -pinhole.position.z)
        let tip = SIMD2(-14.0, -67)
        for height in [20.0, 60, 110, 150] {
            let truth = pinhole.boardMap(tip, height: height, lean: .zero)
            XCTAssertLessThan(simd_distance(camera.projected(tip, heightMM: height), truth), 0.01)
            XCTAssertTrue(camera.bodyZoneContains(pinhole.boardMap(tip, height: height, lean: SIMD2(0.3, -0.3)), tip: tip))
        }
        let away = simd_normalize(tip - camera.footMM)
        XCTAssertFalse(camera.bodyZoneContains(tip - away * 30, tip: tip))   // camera side
        XCTAssertFalse(camera.bodyZoneContains(tip + SIMD2(-away.y, away.x) * 40, tip: tip))   // beside it
    }
}
