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
    /// The best view of the visit being thrown (see `saveVisit`), with its image and its score:
    /// darts seen at `visitDartConfidence` or more.
    private var visitPicture: (entry: Entry, image: Data, darts: Int)?
    static let visitDartConfidence = 0.3

    private let lock = NSLock()
    private var encoding = false   // guarded by `lock`

    /// While a session is recorded (see `startStreaming`): every entry also goes to `detector.jsonl`
    /// and every image to `frames/<seq>.jpg` in this folder. Confined to `queue`.
    private var stream: (folder: URL, log: FileHandle, gameLog: FileHandle)?
    private var streamedImages = 0
    /// Recording stops when the phone has less free space than this.
    static let streamMinFreeBytes: Int64 = 2_000_000_000

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
            // A frame with an image goes to the session recording once its image is saved, so the
            // recorded entry says whether `frames/<seq>.jpg` exists.
            let seq = self.append(Entry(seq: 0, time: time, command: nil, frame: frame), streamNow: toEncode == nil)
            guard let (picture, region) = toEncode else { return }
            let data = Self.modelInputJPEG(picture, region: region, context: self.context)
            self.lock.withLock { self.encoding = false }
            var recorded = Entry(seq: seq, time: time, command: nil, frame: frame)
            guard let data else {
                if let i = self.entries.lastIndex(where: { $0.seq == seq }) { self.entries[i].frame?.image = false }
                recorded.frame?.image = false
                self.streamEntry(recorded)
                return
            }
            self.images.append((seq, time, data))
            self.imageBytes += data.count
            recorded.frame?.image = self.streamImage(data, seq: seq)
            self.streamEntry(recorded)
            self.trim()
            self.considerForVisit(Entry(seq: seq, time: time, command: nil, frame: frame), image: data)
        }
    }

    /// Writes the visit's best view (`<name>.jpg`) and `record` with it (`<name>.json`) into
    /// `folder`, after every frame recorded so far, and starts looking for the next visit's view.
    /// The best view is the clear view, while darts were being thrown, with the most darts seen;
    /// on a tie the later one. Only frames with an image count: a frame arriving while the previous
    /// image is still being encoded has none, but on the phone that was 0.1% of frames, never more
    /// than 3 in a row (2026-11-15), while a board with the same darts stays the same for seconds.
    /// A visit saved again under the same name keeps its earlier picture unless the new one shows more darts.
    func saveVisit(_ record: VisitRecords.Record, into folder: URL, name: String) {
        queue.async {
            var record = record
            var picture = self.visitPicture
            self.visitPicture = nil
            if let earlier = Self.savedPicture(in: folder, name: name), earlier.darts >= (picture?.darts ?? -1) {
                picture = earlier
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if let picture {
                    try picture.image.write(to: folder.appendingPathComponent("\(name).jpg"))
                    record.board = picture.entry
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(record).write(to: folder.appendingPathComponent("\(name).json"))
            } catch {
                print("Saving the visit record failed: \(error)")
            }
        }
    }

    /// The picture already saved under `name` (a visit saved again), read back from disk.
    private static func savedPicture(in folder: URL, name: String) -> (entry: Entry, image: Data, darts: Int)? {
        guard let json = try? Data(contentsOf: folder.appendingPathComponent("\(name).json")),
              let entry = (try? JSONDecoder().decode(VisitRecords.Record.self, from: json))?.board,
              let frame = entry.frame, let darts = visitDarts(in: frame),
              let image = try? Data(contentsOf: folder.appendingPathComponent("\(name).jpg"))
        else { return nil }
        return (entry, image, darts)
    }

    private func considerForVisit(_ entry: Entry, image: Data) {
        guard let frame = entry.frame, let darts = Self.visitDarts(in: frame) else { return }
        if let best = visitPicture, best.darts > darts { return }
        visitPicture = (entry, image, darts)
    }

    /// Darts seen in a clear view while throwing; nil for frames that cannot be a visit's view.
    private static func visitDarts(in frame: Frame) -> Int? {
        guard frame.use == "clear", frame.phase == "throwing" else { return nil }
        return frame.detections.filter { $0.c == RFDetrDecoder.dartClass && $0.p >= visitDartConfidence }.count
    }

    // MARK: Session recording

    /// Records everything from now on into `folder`, for replaying a whole session on a Mac:
    /// `detector.jsonl` holds one `Entry` per line, `frames/<seq>.jpg` the model inputs (an entry's
    /// `image` says whether its file was saved), `game_log.jsonl` and `game.json` what the game sends
    /// (`recordGame`). A new recording starts with the last checkpoint in memory and everything after
    /// it, so a replay starts from a known tracker state; a recording continued in the same folder
    /// (the session started again) just appends. Stops by itself when the phone is nearly full or a
    /// write fails, and with `stopStreaming()`.
    func startStreaming(into folder: URL) {
        queue.async {
            guard self.stream?.folder != folder else { return }
            self.stopStream()
            let log = folder.appendingPathComponent("detector.jsonl")
            let fresh: Bool
            do {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("frames", isDirectory: true),
                                                        withIntermediateDirectories: true)
                let handle = try Self.appendHandle(log)
                fresh = try handle.offset() == 0
                self.stream = (folder, handle, try Self.appendHandle(folder.appendingPathComponent("game_log.jsonl")))
            } catch {
                print("Starting the session recording failed: \(error)")
                self.stopStream()
                return
            }
            guard fresh, let start = self.entries.lastIndex(where: { $0.checkpoint != nil }) else { return }
            for var entry in self.entries[start...] {
                if entry.frame != nil {
                    let image = self.images.first { $0.seq == entry.seq }
                    entry.frame?.image = image.map { self.streamImage($0.data, seq: entry.seq) } ?? false
                }
                self.streamEntry(entry)
            }
        }
    }

    func stopStreaming() { queue.async { self.stopStream() } }

    /// A game log line, appended to `game_log.jsonl` while a session is recorded.
    func recordGame(logLine: MistakeReports.GameFile.LogLine) {
        queue.async {
            guard let stream = self.stream, var data = try? JSONEncoder().encode(logLine) else { return }
            data.append(0x0A)
            do { try stream.gameLog.write(contentsOf: data) } catch { self.streamFailed(error) }
        }
    }

    /// The match as it stands, written to `game.json` while a session is recorded.
    func recordGame(_ file: MistakeReports.GameFile) {
        queue.async {
            guard let stream = self.stream else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Atomic: a failed write keeps the last good copy.
            do { try encoder.encode(file).write(to: stream.folder.appendingPathComponent("game.json"), options: .atomic) } catch { self.streamFailed(error) }
        }
    }

    private static func appendHandle(_ file: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        return handle
    }

    private func stopStream() {
        try? stream?.log.close()
        try? stream?.gameLog.close()
        stream = nil
    }

    private func streamFailed(_ error: Error) {
        print("Session recording stopped: \(error)")
        stopStream()
    }

    private func streamEntry(_ entry: Entry) {
        guard let stream, var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        do { try stream.log.write(contentsOf: line) } catch { streamFailed(error) }
    }

    /// Saves `frames/<seq>.jpg`; false when nothing is recorded or it could not be saved.
    private func streamImage(_ data: Data, seq: Int) -> Bool {
        guard let stream else { return false }
        streamedImages += 1
        if streamedImages % 200 == 0,
           let free = try? stream.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < Self.streamMinFreeBytes {
            print("Session recording stopped: the phone is nearly full")
            stopStream()
            return false
        }
        let file = stream.folder.appendingPathComponent("frames").appendingPathComponent(String(format: "%06d.jpg", seq))
        do {
            try data.write(to: file)
            return true
        } catch {
            streamFailed(error)
            return false
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

    private func append(_ entry: Entry, streamNow: Bool = true) -> Int {
        var entry = entry
        entry.seq = nextSeq
        nextSeq += 1
        entries.append(entry)
        if streamNow { streamEntry(entry) }
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
        case .emptyVisitEnded: return "emptyVisitEnded"
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
