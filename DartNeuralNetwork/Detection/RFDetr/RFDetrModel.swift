import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import simd

/// A camera frame or still image in BGRA, plus how to turn it upright.
///
/// All detector coordinates are pixels of the upright image (x right, y down, pixel edges at
/// integers, as in the training labels).
struct FrameImage {
    enum Orientation {
        /// The buffer is upright.
        case up
        /// The buffer must be turned 90° clockwise (the back camera's sensor in a portrait phone).
        case right
    }

    let pixelBuffer: CVPixelBuffer
    let orientation: Orientation

    var bufferWidth: Int { CVPixelBufferGetWidth(pixelBuffer) }
    var bufferHeight: Int { CVPixelBufferGetHeight(pixelBuffer) }

    /// Size of the upright image.
    var size: CGSize {
        orientation == .up
            ? CGSize(width: bufferWidth, height: bufferHeight)
            : CGSize(width: bufferHeight, height: bufferWidth)
    }

    /// Draws a still image into a new BGRA buffer, without colour conversion (like OpenCV).
    static func make(from image: CGImage) -> FrameImage? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return FrameImage(pixelBuffer: buffer, orientation: .up)
    }
}

/// One detection of the model, after decoding and duplicate merging.
struct ModelDetection: Equatable {
    /// 0...11 calibration points, 12 dart.
    var classIndex: Int
    /// Box centre: the calibration point or the dart tip. Normalised to the model input while
    /// decoding, pixels of the upright frame afterwards.
    var point: SIMD2<Double>
    var confidence: Double

    var isDart: Bool { classIndex == RFDetrDecoder.dartClass }
}

/// Turns the raw RF-DETR outputs into detections. Mirrors `check_coreml.py`.
enum RFDetrDecoder {
    static let queries = 300
    static let logitClasses = 14
    static let calibrationClasses = 12
    static let dartClass = 12

    /// - Parameters:
    ///   - boxes: `queries x 4` values (cx, cy, w, h), normalised to the model input.
    ///   - logits: `queries x 14` class logits.
    /// - Returns: detections sorted by confidence (highest first). Sigmoid over all logits, the top
    ///   300 of all of them, label = index % 14; label 13 is unused and dropped.
    static func decode(boxes: [Float], logits: [Float], minConfidence: Double) -> [ModelDetection] {
        precondition(boxes.count == queries * 4 && logits.count == queries * logitClasses)
        var scored: [(index: Int, p: Double)] = []
        scored.reserveCapacity(logits.count)
        for (index, logit) in logits.enumerated() {
            let p = 1 / (1 + exp(-Double(logit)))
            if p >= minConfidence { scored.append((index, p)) }
        }
        // Top 300 over every (query, class) pair, highest first; ties keep index order.
        scored.sort { $0.p != $1.p ? $0.p > $1.p : $0.index < $1.index }
        if scored.count > queries { scored.removeLast(scored.count - queries) }
        return scored.compactMap { item in
            let query = item.index / logitClasses, label = item.index % logitClasses
            guard label <= dartClass else { return nil }
            return ModelDetection(classIndex: label,
                                  point: SIMD2(Double(boxes[query * 4]), Double(boxes[query * 4 + 1])),
                                  confidence: item.p)
        }
    }

    /// Keeps the most confident of same-class detections closer than `minDistance`.
    static func mergeDuplicates(_ detections: [ModelDetection], minDistance: Double) -> [ModelDetection] {
        var kept: [ModelDetection] = []
        let sorted = detections.enumerated().sorted {
            $0.element.confidence != $1.element.confidence ? $0.element.confidence > $1.element.confidence : $0.offset < $1.offset
        }.map(\.element)
        for d in sorted where !kept.contains(where: { $0.classIndex == d.classIndex && simd_distance($0.point, d.point) < minDistance }) {
            kept.append(d)
        }
        return kept
    }
}

/// Writes the model input: crop, bilinear stretch to `modelInputSide` squared (OpenCV `INTER_LINEAR`
/// sampling, no letterbox), RGB, /255, ImageNet mean and std, NCHW float32.
enum ModelInputWriter {
    static let mean: [Float] = [0.485, 0.456, 0.406]
    static let std: [Float] = [0.229, 0.224, 0.225]

    /// - Parameter crop: region of the upright image in pixels; clamped to the image.
    static func write(_ frame: FrameImage, crop: CGRect, into array: MLMultiArray) {
        let side = DetectorTuning.modelInputSide
        precondition(array.dataType == .float32 && array.count == 3 * side * side)
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let rawHeight = frame.bufferHeight
        let size = frame.size
        let width = Int(size.width), height = Int(size.height)

        // Pixel range of the crop (OpenCV crops whole pixels and replicates the crop's border).
        let x0 = max(0, min(width - 1, Int(crop.minX.rounded(.down))))
        let y0 = max(0, min(height - 1, Int(crop.minY.rounded(.down))))
        let x1 = max(x0 + 1, min(width, Int(crop.maxX.rounded(.up))))
        let y1 = max(y0 + 1, min(height, Int(crop.maxY.rounded(.up))))
        let scaleX = Double(x1 - x0) / Double(side), scaleY = Double(y1 - y0) / Double(side)

        // Byte offset of an upright pixel = rowOffset[uy] + columnOffset[ux], whatever the buffer orientation.
        func columnOffset(_ ux: Int) -> Int { frame.orientation == .up ? ux * 4 : (rawHeight - 1 - ux) * bytesPerRow }
        func rowOffset(_ uy: Int) -> Int { frame.orientation == .up ? uy * bytesPerRow : uy * 4 }

        func taps(_ i: Int, scale: Double, start: Int, end: Int) -> (Int, Int, Float) {
            let s = (Double(i) + 0.5) * scale - 0.5
            var a = Int(s.rounded(.down)), f = s - Double(a)
            if a < 0 { a = 0; f = 0 }
            let last = end - start - 1
            if a >= last { a = last; f = 0 }
            return (start + a, start + min(a + 1, last), Float(f))
        }
        let columns = (0..<side).map { i -> (Int, Int, Float) in
            let (a, b, f) = taps(i, scale: scaleX, start: x0, end: x1)
            return (columnOffset(a), columnOffset(b), f)
        }
        let rows = (0..<side).map { i -> (Int, Int, Float) in
            let (a, b, f) = taps(i, scale: scaleY, start: y0, end: y1)
            return (rowOffset(a), rowOffset(b), f)
        }

        let plane = side * side
        let out = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        let k: [Float] = (0..<3).map { 1 / (255 * std[$0]) }
        let m: [Float] = (0..<3).map { mean[$0] / std[$0] }
        columns.withUnsafeBufferPointer { cols in
            for oy in 0..<side {
                let (r0, r1, fy) = rows[oy]
                let gy = 1 - fy
                for ox in 0..<side {
                    let (c0, c1, fx) = cols[ox]
                    let gx = 1 - fx
                    let p00 = base + r0 + c0, p01 = base + r0 + c1, p10 = base + r1 + c0, p11 = base + r1 + c1
                    let o = oy * side + ox
                    // BGRA in memory; channel c of RGB is byte 2 - c.
                    for c in 0..<3 {
                        let b = 2 - c
                        let top = Float(p00[b]) * gx + Float(p01[b]) * fx
                        let bottom = Float(p10[b]) * gx + Float(p11[b]) * fx
                        let v = (top * gy + bottom * fy).rounded()   // OpenCV rounds to 8 bits
                        out[c * plane + o] = v * k[c] - m[c]
                    }
                }
            }
        }
    }
}

/// The bundled RF-DETR Core ML model (v6rf12h: 800 px input, fp16). Not thread-safe: use from one queue.
final class RFDetrModel {
    static let resourceName = "v6rf12h_fp16"

    private let model: MLModel
    private let input: MLMultiArray
    private let provider: MLFeatureProvider

    init(model: MLModel) throws {
        self.model = model
        let side = DetectorTuning.modelInputSide as NSNumber
        input = try MLMultiArray(shape: [1, 3, side, side], dataType: .float32)
        provider = try MLDictionaryFeatureProvider(dictionary: ["tensors": MLFeatureValue(multiArray: input)])
    }

    static func loadBundled(computeUnits: MLComputeUnits = .all) throws -> RFDetrModel {
        guard let url = Bundle(for: RFDetrModel.self).url(forResource: resourceName, withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try RFDetrModel(model: MLModel(contentsOf: url, configuration: configuration))
    }

    /// Runs the model on `crop` (the whole frame when nil) and returns merged detections at
    /// `DetectorTuning.decodeFloor` or more, in pixels of the upright frame.
    func detect(in frame: FrameImage, crop: CGRect? = nil) throws -> [ModelDetection] {
        let region = Self.inputRegion(crop: crop, frameSize: frame.size)
        ModelInputWriter.write(frame, crop: region, into: input)
        let output = try model.prediction(from: provider)
        guard let (boxes, logits) = Self.outputs(output) else { throw CocoaError(.coderValueNotFound) }
        let decoded = RFDetrDecoder.decode(boxes: boxes, logits: logits, minConfidence: DetectorTuning.decodeFloor)
        return RFDetrDecoder.mergeDuplicates(decoded, minDistance: DetectorTuning.duplicateMergeDistance).map { d in
            var d = d
            d.point = SIMD2(Double(region.minX) + d.point.x * Double(region.width),
                            Double(region.minY) + d.point.y * Double(region.height))
            return d
        }
    }

    /// The part of the frame the model looks at for `crop` (the whole frame when nil).
    static func inputRegion(crop: CGRect?, frameSize: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: frameSize)
        return crop.map { $0.intersection(full).integral } ?? full
    }

    /// The box and logit outputs, found by their last dimension (4 and 14) like the Python check.
    private static func outputs(_ output: MLFeatureProvider) -> ([Float], [Float])? {
        var boxes: [Float]?, logits: [Float]?
        for name in output.featureNames {
            guard let array = output.featureValue(for: name)?.multiArrayValue, array.shape.count == 3 else { continue }
            switch array.shape[2].intValue {
            case 4: boxes = floats(array)
            case RFDetrDecoder.logitClasses: logits = floats(array)
            default: continue
            }
        }
        guard let boxes, let logits else { return nil }
        return (boxes, logits)
    }

    /// Copies a `1 x rows x columns` array into a dense row-major `[Float]`, honouring strides.
    private static func floats(_ array: MLMultiArray) -> [Float] {
        let rows = array.shape[1].intValue, columns = array.shape[2].intValue
        let rowStride = array.strides[1].intValue, columnStride = array.strides[2].intValue
        var out = [Float](repeating: 0, count: rows * columns)
        if array.dataType == .float32 {
            array.withUnsafeBufferPointer(ofType: Float.self) { p in
                for r in 0..<rows { for c in 0..<columns { out[r * columns + c] = p[r * rowStride + c * columnStride] } }
            }
        } else {
            for r in 0..<rows {
                for c in 0..<columns { out[r * columns + c] = array[[0, r, c] as [NSNumber]].floatValue }
            }
        }
        return out
    }
}
