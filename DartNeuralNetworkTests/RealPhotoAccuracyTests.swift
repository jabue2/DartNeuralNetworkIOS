import XCTest
import simd
@testable import DartNeuralNetwork

/// The app's detector on the user's labelled photos (`~/DartSynthetic/real/images/test`, without
/// `d1_`/`d2_`), scored like `eval_public.py` SELFCHECK: a predicted dart matches a labelled one
/// within 20 mm (through the true homography), then its segment through the predicted
/// homography must equal the true segment.
final class RealPhotoAccuracyTests: XCTestCase {
    private struct Labelled {
        let name: String
        let frame: FrameImage
        /// Image pixels → board mm, from the four labelled calibration points.
        let truth: Homography
        let tips: [SIMD2<Double>]
        var segments: [Segment] { tips.map { BoardGeometry.segment(at: BoardPoint(millimetres: truth.apply($0)!)) } }
    }

    private struct Tally {
        var darts = 0, correct = 0, missed = 0, wrong = 0, noBoard = 0, falseDarts = 0, images = 0
        var share: Double { Double(correct) / Double(max(darts, 1)) }
        var line: String {
            String(format: "%d images, %d darts: %.2f%% correct, %d missed, %d wrong segment, %d without board, %.3f false darts per image",
                   images, darts, share * 100, missed, wrong, noBoard, Double(falseDarts) / Double(max(images, 1)))
        }
    }

    private func load(_ name: String) throws -> Labelled {
        let frame = try TestResources.photo(name)
        let base = (name as NSString).deletingPathExtension
        let url = try XCTUnwrap(TestResources.bundle.url(forResource: base, withExtension: "txt"))
        let size = SIMD2(Double(frame.size.width), Double(frame.size.height))
        var calibration: [Int: SIMD2<Double>] = [:], tips: [SIMD2<Double>] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let v = line.split(separator: " ").compactMap { Double($0) }
            guard v.count >= 3 else { continue }
            let p = SIMD2(v[1], v[2]) * size
            if Int(v[0]) == 4 { tips.append(p) } else { calibration[Int(v[0])] = p }
        }
        // One photo (79c09a78-IMG_5557) has no label for point 0. `eval_public.py` then uses (0, 0),
        // which gives a wrong true homography; do the same so the numbers compare one to one.
        if calibration.count < 4 { print("RESULT note: \(name) has only \(calibration.count) labelled calibration points") }
        let classes = [0, 1, 2, 3]
        let truth = try XCTUnwrap(Homography.fit(from: classes.map { calibration[$0] ?? .zero },
                                                 to: classes.map { BoardCalibration.targetsMM[$0] }))
        return Labelled(name: name, frame: frame, truth: truth, tips: tips)
    }

    /// Optimal one-to-one matching (smallest total distance, like `linear_sum_assignment`), then
    /// pairs farther than `limit` are dropped. Returns truth index → prediction index.
    private func match(_ truth: [SIMD2<Double>], _ predicted: [SIMD2<Double>], limit: Double = 20) -> [Int: Int] {
        guard !truth.isEmpty, !predicted.isEmpty else { return [:] }
        let swap = truth.count > predicted.count
        let rows = swap ? predicted : truth, columns = swap ? truth : predicted
        var best: (cost: Double, pairs: [Int])?
        func search(_ row: Int, _ used: Set<Int>, _ pairs: [Int], _ cost: Double) {
            if let best, cost >= best.cost { return }
            if row == rows.count { best = (cost, pairs); return }
            for c in columns.indices where !used.contains(c) {
                search(row + 1, used.union([c]), pairs + [c], cost + simd_distance(rows[row], columns[c]))
            }
        }
        search(0, [], [], 0)
        var result: [Int: Int] = [:]
        for (r, c) in (best?.pairs ?? []).enumerated() where simd_distance(rows[r], columns[c]) <= limit {
            if swap { result[c] = r } else { result[r] = c }
        }
        return result
    }

    /// Scores predicted darts (pixels + segments; nil segment when no board was found).
    private func score(_ photo: Labelled, pixels: [SIMD2<Double>], segments: [Segment]?, into tally: inout Tally) {
        tally.images += 1
        let truthMM = photo.tips.map { photo.truth.apply($0)! }
        let predictedMM = pixels.map { photo.truth.apply($0)! }
        let pairs = match(truthMM, predictedMM)
        let expected = photo.segments
        for i in photo.tips.indices {
            tally.darts += 1
            guard let segments else { tally.noBoard += 1; continue }
            guard let j = pairs[i] else { tally.missed += 1; continue }
            if segments[j] == expected[i] { tally.correct += 1 } else { tally.wrong += 1 }
        }
        tally.falseDarts += pixels.count - pairs.count
    }

    private var photos: [String] {
        TestResources.photoNames
    }

    // MARK: Single image

    /// The full single-image path: Core ML, decoding, calibration, RANSAC homography, scoring.
    /// Offline, the Python pipeline with this model gets 94.61% of these 297 darts.
    func testSingleImageScoringOnLabelledPhotos() throws {
        try TestResources.requirePhotos()
        let model = try XCTUnwrap(TestResources.model, "model did not load")
        XCTAssertEqual(photos.count, 126)
        let python = try XCTUnwrap(TestResources.json("python_scores") as? [String: Any])
        let pythonRows = Dictionary(uniqueKeysWithValues: ((python["rows"] as? [[String: Any]]) ?? []).map {
            ($0["name"] as! String, ($0["darts"] as! [[String: Any]]).map { $0["predicted"] as? String })
        })
        var full = Tally(), cropped = Tally()
        var differentFromPython = 0
        for name in photos {
            let photo = try load(name)
            let observation = FrameObservation(imageSize: photo.frame.size, detections: try model.detect(in: photo.frame))
            let result = SingleImageResult(observation)
            score(photo, pixels: result.darts.map(\.pixel), segments: result.calibration == nil ? nil : result.darts.map(\.segment), into: &full)

            // Per-dart comparison with the Python Core ML run of the same rules.
            let pairs = match(photo.tips.map { photo.truth.apply($0)! }, result.darts.map { photo.truth.apply($0.pixel)! })
            let swiftLabels: [String?] = photo.tips.indices.map { i in pairs[i].map { result.darts[$0].segment.evalLabel } }
            if let reference = pythonRows[(name as NSString).deletingPathExtension], reference != swiftLabels { differentFromPython += 1 }

            // Second pass on the board crop, as the live detector does once locked.
            var second = result
            var secondPixels = result.darts.map(\.pixel)
            if let fit = result.calibration, let crop = Self.crop(fit.homography, imageSize: photo.frame.size) {
                let o = FrameObservation(imageSize: photo.frame.size, crop: crop, detections: try model.detect(in: photo.frame, crop: crop))
                second = SingleImageResult(o)
                secondPixels = second.darts.map(\.pixel)
            }
            score(photo, pixels: secondPixels, segments: second.calibration == nil ? nil : second.darts.map(\.segment), into: &cropped)
        }
        print("RESULT single image, whole photo, conf 0.25: \(full.line)")
        print("RESULT single image, board crop second pass, conf 0.25: \(cropped.line)")
        print("RESULT photos where Swift and Python Core ML differ in a dart's label: \(differentFromPython) of \(photos.count)")
        XCTAssertGreaterThanOrEqual(full.share, 0.92, full.line)
    }

    /// The live pipeline on stills: each photo held in front of the "camera" for 15 frames
    /// (lock, crop, tracks). On a still every frame repeats, so this shows what persistence
    /// recovers when a dart's confidence is steady; it cannot show flicker of a real camera.
    func testMultiFrameTrackerOnHeldPhotos() throws {
        try TestResources.requirePhotos()
        let model = try XCTUnwrap(TestResources.model, "model did not load")
        var tally = Tally()
        var reported = 0
        for name in photos {
            let photo = try load(name)
            var tracker = MultiFrameTracker(ignoresDartsAtStart: false)
            // Identical frames give identical detections: run the model once per crop.
            var cache: [String: [ModelDetection]] = [:]
            for _ in 0..<15 {
                let crop = tracker.crop
                let key = crop.map { "\($0)" } ?? "full"
                if cache[key] == nil { cache[key] = try model.detect(in: photo.frame, crop: crop) }
                _ = tracker.process(FrameObservation(imageSize: photo.frame.size, crop: crop, detections: cache[key]!))
            }
            let toImage = tracker.homography?.inverse
            let darts = tracker.visitDarts
            reported += darts.count
            score(photo, pixels: darts.compactMap { toImage?.apply($0.boardMM) },
                  segments: tracker.isLocked ? darts.map(\.segment) : nil, into: &tally)
        }
        print("RESULT multi-frame tracker, photo held 15 frames: \(tally.line) (\(reported) darts reported)")
        XCTAssertGreaterThanOrEqual(tally.share, 0.9, tally.line)
    }

    /// Same crop rule as `MultiFrameTracker` (board edge + 2% margin).
    private static func crop(_ h: Homography, imageSize: CGSize) -> CGRect? {
        guard let inverse = h.inverse else { return nil }
        let points = (0..<72).compactMap { i -> SIMD2<Double>? in
            let a = Double(i) * .pi / 36
            return inverse.apply(SIMD2(cos(a), sin(a)) * DetectorTuning.boardEdgeMM)
        }
        let lo = points.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }
        let hi = points.reduce(-SIMD2(Double.infinity, .infinity)) { simd_max($0, $1) }
        let m = (hi - lo) * DetectorTuning.cropMargin
        let box = CGRect(x: lo.x - m.x, y: lo.y - m.y, width: hi.x - lo.x + 2 * m.x, height: hi.y - lo.y + 2 * m.y)
            .intersection(CGRect(origin: .zero, size: imageSize))
        return box.isNull || box.width < 96 ? nil : box.integral
    }

    // MARK: Engine and source

    /// The engine processes frames on its queue and emits status before darts, in order.
    func testEngineReportsReadyThenDartsForAHeldPhoto() throws {
        try TestResources.requirePhotos()
        let photo = try load(photos.first { $0.hasPrefix("02491f68") } ?? photos[0])
        let engine = DetectionEngine(ignoresDartsAtStart: false)
        var outputs: [DetectionEvent] = []
        engine.output = { outputs += $0.events }
        engine.queue.sync {
            for i in 0..<15 { engine.process(photo.frame, time: 1 + Double(i) / 10) }
        }
        let statuses = outputs.compactMap { if case .status(let s) = $0 { return s } else { return nil } }
        XCTAssertEqual(statuses.last, .ready)
        let darts = outputs.compactMap { if case .dartDetected(let d) = $0 { return d.segment } else { return nil } }
        XCTAssertEqual(darts.count, photo.tips.count)
        XCTAssertEqual(Set(darts), Set(photo.segments))
        let firstDart = outputs.firstIndex { if case .dartDetected = $0 { return true } else { return false } }!
        XCTAssertLessThan(outputs.firstIndex(of: .status(.ready))!, firstDart)
    }

    /// The source delivers engine events on the main actor.
    @MainActor
    func testSourceDeliversEventsOnTheMainActor() async throws {
        try TestResources.requirePhotos()
        let photo = try load(photos.first { $0.hasPrefix("02491f68") } ?? photos[0])
        let feed = StillFeed(frame: photo.frame)
        let source = RFDetrDetectionSource(feed: feed, ignoresDartsAtStart: false)
        let gotDart = expectation(description: "dart")
        gotDart.assertForOverFulfill = false
        var onMain = true
        source.onEvent = { event in
            onMain = onMain && Thread.isMainThread
            if case .dartDetected = event { gotDart.fulfill() }
        }
        source.start()
        await fulfillment(of: [gotDart], timeout: 60)
        source.stop()
        XCTAssertTrue(onMain)
        XCTAssertEqual(source.status, .ready)
    }
}

/// Feeds one still frame at 10 frames per second.
@MainActor
private final class StillFeed: FrameFeed {
    let frame: FrameImage
    private var timer: DispatchSourceTimer?
    init(frame: FrameImage) { self.frame = frame }

    func start(engine: DetectionEngine, preview: PreviewHostView, failed: @escaping @MainActor () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: engine.queue)
        timer.schedule(deadline: .now(), repeating: 0.1)
        let frame = self.frame
        timer.setEventHandler { engine.process(frame, time: CACurrentMediaTime()) }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel(); timer = nil }
}

private extension Segment {
    /// Labels as `eval_public.py` writes them.
    var evalLabel: String {
        switch self {
        case .miss: return "miss"
        case .bull: return "DB"
        case .outerBull: return "SB"
        case .single(let n): return "S\(n)"
        case .double(let n): return "D\(n)"
        case .triple(let n): return "T\(n)"
        }
    }
}
