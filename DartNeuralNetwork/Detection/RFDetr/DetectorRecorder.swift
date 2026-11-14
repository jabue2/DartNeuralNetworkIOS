import CoreImage
import Foundation
import QuartzCore

/// Keeps the last seconds of what the detector saw, so a reported mistake can be replayed on a Mac.
///
/// Per processed frame it logs the model's raw detections (everything at `decodeFloor` or more),
/// the region the model looked at, the tracker's events and state afterwards, and the game's
/// commands in between. The tracker is deterministic, so these replay it exactly
/// (`MultiFrameTracker.process` with the logged detections and commands), starting from a
/// checkpoint: a copy of the tracker's whole state, logged when the engine starts and every
/// `DetectionEngine` checkpoint interval. Trimming always cuts at a checkpoint, so every log
/// starts with one and covers `logSeconds` plus up to one interval. Per frame it also keeps
/// the model's input as a JPEG (the crop stretched to the input square), to see what the model
/// got wrong; images are kept for a shorter time than the log.
///
/// State lives on `queue`. Images are encoded there one at a time: a frame arriving while one is
/// being encoded is logged without an image, so camera buffers are never held for long.
final class DetectorRecorder: @unchecked Sendable {
    struct Detection: Codable, Equatable {
        /// Class: 0...11 calibration points, 12 dart.
        var c: Int
        /// Pixels of the upright frame.
        var x: Double
        var y: Double
        var p: Double
    }

    struct TrackedDart: Codable, Equatable {
        var label: String
        /// Board millimetres from the centre (x right, y down).
        var x: Double
        var y: Double
    }

    struct Frame: Codable {
        var width: Double
        var height: Double
        /// x, y, width, height of the region the model looked at (pixels of the upright frame).
        var crop: [Double]
        var detections: [Detection]
        /// Tracker state after this frame.
        var events: [String]
        var phase: String
        var use: String
        var status: String
        /// Image pixels → board millimetres, row-major, while locked.
        var homography: [Double]?
        var visitDarts: [TrackedDart]
        var oldDarts: [TrackedDart]
        var inferenceMilliseconds: Double
        /// `frames/<seq>.jpg` exists.
        var image: Bool
    }

    struct Entry: Codable {
        var seq: Int
        /// Seconds on the host clock (`CACurrentMediaTime`; camera frame times use the same clock).
        var time: Double
        /// "endVisit", "resumeVisit", "reset" or "cameraStopped".
        var command: String?
        var frame: Frame?
        /// The tracker's state before the next entry; a replay starts from the first one.
        var checkpoint: MultiFrameTracker?
    }

    struct Summary: Equatable {
        var entries: Int
        var images: Int
    }

    let queue = DispatchQueue(label: "jb.darts.recorder", qos: .utility)
    let logSeconds: Double
    let imageSeconds: Double
    let maxImageBytes: Int

    // Confined to `queue`.
    private var entries: [Entry] = []
    private var images: [(seq: Int, time: Double, data: Data)] = []
    private var imageBytes = 0
    private var nextSeq = 0
    private lazy var context = CIContext(options: [.cacheIntermediates: false])

    private let lock = NSLock()
    private var encoding = false   // guarded by `lock`

    init(logSeconds: Double = 180, imageSeconds: Double = DetectorRecorder.defaultImageSeconds, maxImageBytes: Int = 60_000_000) {
        self.logSeconds = logSeconds
        self.imageSeconds = imageSeconds
        self.maxImageBytes = maxImageBytes
    }

    // MARK: Recording (any queue)

    /// Logs a processed frame; encodes `image` (the model's input region) unless one is still being encoded.
    func record(frame: Frame, time: Double, image: (FrameImage, CGRect)?) {
        var frame = frame
        let encodeNow = image != nil && lock.withLock { () -> Bool in
            guard !encoding else { return false }
            encoding = true
            return true
        }
        frame.image = encodeNow
        // Only an image that is encoded is captured: a skipped one must not hold its camera buffer.
        let toEncode = encodeNow ? image : nil
        queue.async {
            let seq = self.append(Entry(seq: 0, time: time, command: nil, frame: frame))
            guard let (picture, region) = toEncode else { return }
            let data = Self.modelInputJPEG(picture, region: region, context: self.context)
            self.lock.withLock { self.encoding = false }
            guard let data else {
                if let i = self.entries.lastIndex(where: { $0.seq == seq }) { self.entries[i].frame?.image = false }
                return
            }
            self.images.append((seq, time, data))
            self.imageBytes += data.count
            self.trim()
        }
    }

    func record(command: String, time: Double = CACurrentMediaTime()) {
        queue.async { _ = self.append(Entry(seq: 0, time: time, command: command, frame: nil)) }
    }

    func record(checkpoint: MultiFrameTracker, time: Double = CACurrentMediaTime()) {
        queue.async { _ = self.append(Entry(seq: 0, time: time, command: nil, frame: nil, checkpoint: checkpoint)) }
    }

    /// Writes `detector.json` and `frames/<seq>.jpg` into `folder` after everything recorded so
    /// far, then calls `completion` (on `queue`).
    func save(to folder: URL, completion: @escaping (Summary?) -> Void) {
        queue.async {
            do {
                let frames = folder.appendingPathComponent("frames", isDirectory: true)
                try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
                for image in self.images {
                    try image.data.write(to: frames.appendingPathComponent(String(format: "%06d.jpg", image.seq)))
                }
                let kept = Set(self.images.map(\.seq))
                let log = self.entries.map { entry -> Entry in
                    var entry = entry
                    if entry.frame != nil { entry.frame?.image = kept.contains(entry.seq) }
                    return entry
                }
                let file = DetectorLogFile(modelInputSide: DetectorTuning.modelInputSide, entries: log)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(file).write(to: folder.appendingPathComponent("detector.json"))
                completion(Summary(entries: log.count, images: self.images.count))
            } catch {
                print("Saving the detector recording failed: \(error)")
                completion(nil)
            }
        }
    }

    // MARK: Private (on `queue`)

    private func append(_ entry: Entry) -> Int {
        var entry = entry
        entry.seq = nextSeq
        nextSeq += 1
        entries.append(entry)
        trim()
        return entry.seq
    }

    private func trim() {
        guard let newest = entries.last?.time else { return }
        // Cut at the last checkpoint before the window, so the log still replays from a known state.
        if let first = entries.firstIndex(where: { newest - $0.time <= logSeconds }),
           let cut = entries[...first].lastIndex(where: { $0.checkpoint != nil }), cut > 0 {
            entries.removeFirst(cut)
        }
        while let oldest = images.first, newest - oldest.time > imageSeconds || imageBytes > maxImageBytes {
            imageBytes -= oldest.data.count
            images.removeFirst()
        }
    }

    /// The region the model looked at, stretched to the input square like the model's input, as a JPEG.
    static func modelInputJPEG(_ frame: FrameImage, region: CGRect, context: CIContext,
                               side: Int = DetectorTuning.modelInputSide, quality: Double = 0.6) -> Data? {
        guard region.width >= 1, region.height >= 1 else { return nil }
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        if frame.orientation == .right { image = image.oriented(.right) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        // Core Image puts the origin bottom left; detector pixels have it top left.
        let flipped = CGRect(x: region.minX, y: image.extent.height - region.maxY, width: region.width, height: region.height)
        let side = CGFloat(side)
        let input = image.cropped(to: flipped)
            .transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
            .transformed(by: CGAffineTransform(scaleX: side / flipped.width, y: side / flipped.height))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(
            of: input, colorSpace: space,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }
}

/// `detector.json` of a saved report.
struct DetectorLogFile: Codable {
    var modelInputSide: Int
    var entries: [DetectorRecorder.Entry]
}

extension DetectorRecorder {
    static func describe(_ event: DetectionEvent) -> String {
        switch event {
        case .status(let status): return "status \(ScoreboardSnapshot.name(of: status))"
        case .dartDetected(let dart):
            let mm = dart.boardPosition.map { String(format: " at %.3f,%.3f", $0.x, $0.y) } ?? ""
            return String(format: "dart %@ %.2f", dart.segment.label, dart.confidence) + mm
        case .visitEnded: return "visitEnded"
        case .boardCleared: return "boardCleared"
        }
    }

    static func name(of phase: MultiFrameTracker.Phase) -> String {
        switch phase {
        case .throwing: return "throwing"
        case .awaitingRemoval: return "awaitingRemoval"
        case .resetBarrier: return "resetBarrier"
        }
    }

    static func name(of use: MultiFrameTracker.FrameUse) -> String {
        switch use {
        case .forming(let streak): return "forming \(streak)"
        case .usable(let clearView): return clearView ? "clear" : "usable"
        case .occluded: return "occluded"
        case .moved: return "moved"
        case .noBoard: return "noBoard"
        }
    }
}
