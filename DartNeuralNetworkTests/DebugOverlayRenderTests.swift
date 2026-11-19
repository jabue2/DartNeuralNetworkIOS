import SwiftUI
import XCTest
@testable import DartNeuralNetwork

/// Renders the detector view over a real photo with a real engine snapshot, for checking the
/// drawing by eye (rings on the wires, labels readable). Runs only when `RENDER_OUT` names a
/// folder (`TEST_RUNNER_RENDER_OUT=<folder> xcodebuild test ...`). This is a SwiftUI render, not
/// a device screenshot: the live camera preview is replaced by the photo.
@MainActor
final class DebugOverlayRenderTests: XCTestCase {
    func testRenderDetectorViewOverPhoto() throws {
        guard let out = ProcessInfo.processInfo.environment["RENDER_OUT"] else { throw XCTSkip("RENDER_OUT not set") }
        let name = "02491f68-IMG_5656.jpeg"
        let frame = try TestResources.photo(name)
        let engine = DetectionEngine(ignoresDartsAtStart: false)
        var snapshot: DetectorSnapshot?
        engine.output = { if let s = $0.snapshot { snapshot = s } }
        engine.setDebugEnabled(true)
        engine.queue.sync { for i in 0..<12 { engine.process(frame, time: 1 + Double(i) / 10) } }
        let model = DetectorDebugModel()
        model.isShown = true
        model.publish(try XCTUnwrap(snapshot))

        let url = TestResources.bundle.url(forResource: "02491f68-IMG_5656", withExtension: "jpeg")!
        let photo = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        for scheme in [ColorScheme.light, .dark] {
            let view = ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: photo).resizable().scaledToFill().frame(width: 402, height: 874).clipped()
                DetectorDebugOverlay(model: model)
                DetectorDebugPanel(model: model).padding(.leading, 20).padding(.top, 62 + 52)
            }
            .frame(width: 402, height: 874)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            try image.pngData()!.write(to: URL(fileURLWithPath: out).appendingPathComponent("render_detector_view_\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
