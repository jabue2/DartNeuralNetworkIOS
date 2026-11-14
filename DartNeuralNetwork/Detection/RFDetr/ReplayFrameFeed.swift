#if DEBUG
import ImageIO
import UIKit

/// DEBUG only: feeds still images through the real RF-DETR pipeline as if they were camera
/// frames, so the model, tracker and debug view run in the simulator.
///
/// Launch arguments:
///   -replayFolder <path>   folder of .jpg/.jpeg/.png images, played in name order (required)
///   -replayHold <seconds>  how long each image stays "in front of the camera" (default 6)
///   -replayFPS <n>         frames per second fed to the engine (default 8)
/// Each image is held like a still camera view; switching images looks like the camera moved.
@MainActor
final class ReplayFrameFeed: FrameFeed {
    private struct Still {
        let frame: FrameImage
        let image: UIImage
    }

    private let stills: [Still]
    private let hold: Double
    private let framesPerSecond: Double
    private var timer: DispatchSourceTimer?
    private let imageView = UIImageView()
    private var shownIndex = -1

    init?(folder: URL, hold: Double = 6, framesPerSecond: Double = 8) {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("._") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        stills = urls.compactMap { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let frame = FrameImage.make(from: image) else { return nil }
            return Still(frame: frame, image: UIImage(cgImage: image))
        }
        guard !stills.isEmpty else { return nil }
        self.hold = max(0.5, hold)
        self.framesPerSecond = min(30, max(1, framesPerSecond))
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
    }

    /// The replay source for this launch, if `-replayFolder` names a folder with images.
    static func fromLaunchArguments() -> ReplayFrameFeed? {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "replayFolder") else { return nil }
        let hold = defaults.double(forKey: "replayHold")
        let fps = defaults.double(forKey: "replayFPS")
        return ReplayFrameFeed(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                               hold: hold > 0 ? hold : 6, framesPerSecond: fps > 0 ? fps : 8)
    }

    func start(engine: DetectionEngine, preview: PreviewHostView, failed: @escaping @MainActor () -> Void) {
        if imageView.superview !== preview { preview.addSubview(imageView) }
        timer?.cancel()
        let frames = stills.map(\.frame)
        let hold = self.hold
        let started = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: engine.queue)
        timer.schedule(deadline: .now(), repeating: 1 / framesPerSecond)
        timer.setEventHandler { [weak self] in
            let now = CACurrentMediaTime()
            let index = Int((now - started) / hold) % frames.count
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(index) } }
            engine.process(frames[index], time: now)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func show(_ index: Int) {
        guard index != shownIndex else { return }
        shownIndex = index
        imageView.image = stills[index].image
    }
}
#endif
