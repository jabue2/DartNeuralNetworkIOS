import CoreML
import ImageIO
import XCTest
import simd
@testable import DartNeuralNetwork

/// Fixtures and photos bundled with the test target (see `app_rfdetr/fixtures/make_fixtures.py`).
///
/// The photos (`RealPhotos/`) are the user's own and are not in the public repository: tests that
/// need them skip when they are missing (`requirePhotos()`, `photo(_:)`), before loading the model.
enum TestResources {
    static let bundle = Bundle(for: BundleToken.self)
    private final class BundleToken {}

    static func json(_ name: String) throws -> Any {
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "missing \(name).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    /// Skips the calling test when the private photos are not in this checkout.
    static func requirePhotos() throws {
        if photoNames.isEmpty { throw XCTSkip("The private test photos (DartNeuralNetworkTests/RealPhotos) are not in this checkout") }
    }

    /// A photo of `RealPhotos/`; skips the calling test when it is missing.
    static func photo(_ fileName: String) throws -> FrameImage {
        guard let url = bundle.url(forResource: (fileName as NSString).deletingPathExtension,
                                   withExtension: (fileName as NSString).pathExtension) else {
            throw XCTSkip("Private test photo \(fileName) is not in this checkout (DartNeuralNetworkTests/RealPhotos)")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(FrameImage.make(from: image))
    }

    /// The labelled test photos (names without `d1_`, `d2_`, `._`), sorted.
    static var photoNames: [String] {
        let urls = (bundle.urls(forResourcesWithExtension: "jpeg", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [])
        return urls.map(\.lastPathComponent)
            .filter { !$0.hasPrefix("d1_") && !$0.hasPrefix("d2_") && !$0.hasPrefix("._") }
            .sorted()
    }

    /// One model for all tests (loading takes a while).
    static let model: RFDetrModel? = try? RFDetrModel.loadBundled()
}

/// Rows `[label, cx, cy, conf]` from the Python fixtures.
private func rows(_ any: Any?) -> [[Double]] {
    ((any as? [[Any]]) ?? []).map { $0.map { ($0 as? NSNumber)?.doubleValue ?? .nan } }
}

final class RFDetrDecodingTests: XCTestCase {
    /// Decoding the raw model outputs gives exactly what the Python reference decoded.
    func testDecodeMatchesPythonReference() throws {
        let cases = try XCTUnwrap(TestResources.json("decode_fixture") as? [[String: Any]])
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let boxes = rows(c["boxes"]).flatMap { $0.map(Float.init) }
            let logits = rows(c["logits"]).flatMap { $0.map(Float.init) }
            let decoded = RFDetrDecoder.decode(boxes: boxes, logits: logits, minConfidence: 0.02)
            assertSame(decoded, rows(c["decoded"]), "\(c["name"]!) decoded")
            let merged = RFDetrDecoder.mergeDuplicates(decoded, minDistance: 0.02)
            assertSame(merged, rows(c["merged"]), "\(c["name"]!) merged")
            XCTAssertFalse(merged.contains { $0.classIndex == 13 })
        }
    }

    private func assertSame(_ swift: [ModelDetection], _ python: [[Double]], _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(swift.count, python.count, message, file: file, line: line)
        let key: ([Double]) -> String = { String(format: "%02d %.5f %.5f", Int($0[0]), $0[1], $0[2]) }
        let a = swift.map { [Double($0.classIndex), $0.point.x, $0.point.y, $0.confidence] }.sorted { key($0) < key($1) }
        let b = python.sorted { key($0) < key($1) }
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x[0], y[0], message, file: file, line: line)
            XCTAssertEqual(x[1], y[1], accuracy: 1e-5, message, file: file, line: line)
            XCTAssertEqual(x[2], y[2], accuracy: 1e-5, message, file: file, line: line)
            XCTAssertEqual(x[3], y[3], accuracy: 1e-5, message, file: file, line: line)
        }
    }

    func testMergeKeepsMostConfidentOfCloseSameClassDetections() {
        let d = [
            ModelDetection(classIndex: 12, point: SIMD2(0.50, 0.50), confidence: 0.4),
            ModelDetection(classIndex: 12, point: SIMD2(0.51, 0.50), confidence: 0.7),   // 1% away: same dart
            ModelDetection(classIndex: 12, point: SIMD2(0.53, 0.50), confidence: 0.3),   // 2% from the kept one: separate
            ModelDetection(classIndex: 3, point: SIMD2(0.51, 0.50), confidence: 0.9),    // other class: kept
        ]
        let merged = RFDetrDecoder.mergeDuplicates(d, minDistance: 0.02)
        XCTAssertEqual(merged.map(\.confidence), [0.9, 0.7, 0.3])
    }

    /// The model input matches OpenCV's resize and normalisation (JPEG decoders differ by a level or two).
    func testPreprocessingMatchesPython() throws {
        try TestResources.requirePhotos()
        let cases = try XCTUnwrap(TestResources.json("preprocess_fixture") as? [[String: Any]])
        let side = DetectorTuning.modelInputSide as NSNumber
        let array = try MLMultiArray(shape: [1, 3, side, side], dataType: .float32)
        for c in cases {
            let frame = try TestResources.photo(c["name"] as! String)
            let crop = (c["crop"] as! [NSNumber]).map(\.doubleValue)
            ModelInputWriter.write(frame, crop: CGRect(x: crop[0], y: crop[1], width: crop[2] - crop[0], height: crop[3] - crop[1]),
                                   into: array)
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            let indices = (c["indices"] as! [NSNumber]).map(\.intValue)
            let values = (c["values"] as! [NSNumber]).map(\.doubleValue)
            var worst = 0.0, total = 0.0
            for (i, v) in zip(indices, values) {
                let d = abs(Double(pointer[i]) - v)
                worst = max(worst, d); total += d
            }
            // One 8-bit level is 1/255/0.225 ≈ 0.017 after normalisation.
            XCTAssertLessThan(total / Double(indices.count), 0.03, "mean difference, crop \(crop)")
            XCTAssertLessThan(worst, 0.2, "largest difference, crop \(crop)")
            let plane = DetectorTuning.modelInputSide * DetectorTuning.modelInputSide
            for (channel, mean) in ((c["channel_means"] as! [NSNumber]).map(\.doubleValue)).enumerated() {
                var sum = 0.0
                for k in 0..<plane { sum += Double(pointer[channel * plane + k]) }
                XCTAssertEqual(sum / Double(plane), mean, accuracy: 0.01, "channel \(channel) mean, crop \(crop)")
            }
        }
    }

    /// The upright sampling of a rotated buffer equals sampling the upright image.
    func testRotatedBufferSamplesLikeUprightImage() throws {
        let upright = try TestResources.photo("02491f68-IMG_5656.jpeg")
        // Turn the buffer 90° counter-clockwise, so `.right` brings it back upright.
        let w = upright.bufferWidth, h = upright.bufferHeight
        var rotated: CVPixelBuffer?
        CVPixelBufferCreate(nil, h, w, kCVPixelFormatType_32BGRA, nil, &rotated)
        let r = try XCTUnwrap(rotated)
        CVPixelBufferLockBaseAddress(upright.pixelBuffer, .readOnly); CVPixelBufferLockBaseAddress(r, [])
        let src = CVPixelBufferGetBaseAddress(upright.pixelBuffer)!.assumingMemoryBound(to: UInt32.self)
        let dst = CVPixelBufferGetBaseAddress(r)!.assumingMemoryBound(to: UInt32.self)
        let srcRow = CVPixelBufferGetBytesPerRow(upright.pixelBuffer) / 4, dstRow = CVPixelBufferGetBytesPerRow(r) / 4
        // Upright (x, y) sits at raw (y, rawHeight - 1 - x) with rawHeight = w.
        for y in 0..<h { for x in 0..<w { dst[(w - 1 - x) * dstRow + y] = src[y * srcRow + x] } }
        CVPixelBufferUnlockBaseAddress(upright.pixelBuffer, .readOnly); CVPixelBufferUnlockBaseAddress(r, [])
        let turned = FrameImage(pixelBuffer: r, orientation: .right)
        XCTAssertEqual(turned.size, upright.size)

        let side = DetectorTuning.modelInputSide as NSNumber
        let a = try MLMultiArray(shape: [1, 3, side, side], dataType: .float32)
        let b = try MLMultiArray(shape: [1, 3, side, side], dataType: .float32)
        let crop = CGRect(x: 100, y: 40, width: 600, height: 500)
        ModelInputWriter.write(upright, crop: crop, into: a)
        ModelInputWriter.write(turned, crop: crop, into: b)
        let pa = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
        let pb = b.dataPointer.bindMemory(to: Float.self, capacity: b.count)
        var worst: Float = 0
        for i in 0..<a.count { worst = max(worst, abs(pa[i] - pb[i])) }
        XCTAssertEqual(worst, 0, accuracy: 1e-6)
    }

    /// The full Core ML path on photos finds what the Python Core ML path found.
    func testCoreMLDetectionsMatchPython() throws {
        try TestResources.requirePhotos()
        let model = try XCTUnwrap(TestResources.model, "model did not load")
        let cases = try XCTUnwrap(TestResources.json("coreml_fixture") as? [[String: Any]])
        for c in cases {
            let name = c["name"] as! String
            let frame = try TestResources.photo(name)
            let size = SIMD2(Double(frame.size.width), Double(frame.size.height))
            let swift = try model.detect(in: frame).filter { $0.confidence >= 0.1 }
            let python = rows(c["detections"])
            var matched = 0
            for p in python {
                let point = SIMD2(p[1], p[2]) * size
                let near = swift.filter { $0.classIndex == Int(p[0]) && simd_distance($0.point, point) < 3 }
                if let best = near.min(by: { simd_distance($0.point, point) < simd_distance($1.point, point) }) {
                    matched += 1
                    // fp16 rounding on the simulator vs Python's CPU run moves weak detections a little more
                    // at 800 px; confident ones must agree tightly. Scores are compared end to end in
                    // RealPhotoAccuracyTests (Swift and Python labels must agree on every dart).
                    XCTAssertEqual(best.confidence, p[3], accuracy: p[3] >= 0.3 ? 0.05 : 0.08, "\(name) class \(Int(p[0]))")
                } else {
                    // Only borderline detections may be missing.
                    XCTAssertLessThan(p[3], 0.15, "\(name): Python detection \(p) not found")
                }
            }
            // Every detection Python finds at 0.15 or more must be found (asserted above); only weaker ones may be missing.
            XCTAssertGreaterThanOrEqual(matched, python.filter { $0[3] >= 0.15 }.count, name)
            print("RESULT coreml-vs-python \(name): \(matched) of \(python.count) detections matched, swift \(swift.count)")
        }
    }
}
