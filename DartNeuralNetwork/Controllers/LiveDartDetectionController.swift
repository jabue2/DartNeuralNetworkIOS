import AVFoundation
import SwiftUI
import UIKit
import Vision

// MARK: - Models

struct TrackedDart {
    var bbox: CGRect      // normalized Vision bbox
    var confidence: CGFloat
    var classId: Int
}

struct DetectionOverlay {
    var dartCenters: [CGPoint] = []
    var dartBoxes: [CGRect] = []
}

struct DartHit: Equatable {
    let center: CGPoint      // normalized image-space (cropped) center
    let label: String        // e.g., "T20", "D16", "S20", "Bull", etc.
    let points: Int
}

// MARK: - Controller

final class LiveDartDetectionController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, ObservableObject {

    // Capture
    private(set) var captureSession: AVCaptureSession!
    private(set) var videoPreviewLayer: AVCaptureVideoPreviewLayer!
    private let detectionQueue = DispatchQueue(label: "com.yourapp.dartDetectionQueue")

    // UI-observed
    @Published var overlay: DetectionOverlay = .init()
    @Published var lastScoreText: String = ""
    @Published var gameScore: Int = 0
    @Published var throwHistory: [String] = []
    @Published var totalThrows: [String] = []
    @Published var dartsThisLeg: Int = 0
    @Published var isPaused: Bool = false
    @Published var isWaitingForRemoval: Bool = false
    @Published var isGameOver: Bool = false

    // Run UI updates safely on main
    @inline(__always)
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async { work() } }
    }

    // --- De-dup / stabilization knobs ---
    private let minCenterSeparation: CGFloat = 0.05   // NMS distance for same dart
    private let cooldownFramesAfterConfirm = 3        // frames to ignore new confirmation after one is accepted
    private var newDartCooldown = 0                   // decremented each processed frame

    // False-positive filtering
    private let dartConfidenceThreshold: CGFloat = 0.45
    private let minBoxAreaNorm: CGFloat = 0.00005     // ~0.005% of cropped image
    private let maxBoxAreaNorm: CGFloat = 0.04        // ~4% of cropped image
    private let aspectRatioRange: ClosedRange<CGFloat> = 0.15...6.0 // very permissive

    // Board gating (in board-plane units; 1.0 ~= board radius)
    private let maxBoardRadiusNorm: CGFloat = 1.02
    private let minBoardRadiusNorm: CGFloat = 0.15

    var onDetectionUpdate: ((UIImage?, String) -> Void)?

    weak var previewView: UIView?
    var processor: DartboardProcessing? = DartboardProcessing()

    // Timing / cadence
    private var lastDetectionTime: TimeInterval = 0
    var detectionInterval: TimeInterval = 0.35

    // Tracking
    private var trackedDarts: [TrackedDart] = []

    // Game mode
    var gameMode: Int? = nil // 301/501/nil

    // --- Turn state machine ---
    private enum TurnState { case waitingForBoard, detecting, waitingForRemoval }
    private var state: TurnState = .waitingForBoard

    // After finalizing a turn, we wait until darts are removed
    private var lastTurnCenters: [CGPoint] = []          // cropped-normalized centers of finalized darts
    private var framesSinceClear: Int = 0
    private let framesNeededClear = 6                    // tune for FPS/behavior

    // Keep these so we can edit the last turn
    private var lastFinalizedTurn: [DartHit] = []
    private var lastFinalizedTurnStartScore: Int?

    private var currentTurn: [DartHit] = []      // confirmed darts this turn (0..3)
    private var scoreAtTurnStart: Int = 0

    // Stabilization for new dart confirmation
    private var candidateNewDart: (center: CGPoint, frames: Int)?
    private let stabilizationFramesNeeded = 2
    private let newDartDistanceThreshold: CGFloat = 0.06 // “new dart” distance from confirmed

    // Board visibility / occlusion (player steps in front)
    private var boardVisibleStreak = 0
    private var occludedStreak = 0
    private let boardVisibleThreshold = 2
    private let occludedThreshold = 6

    // MARK: - Session Management

    func startSession(in view: UIView) {
        previewView = view

        let session = AVCaptureSession()
        session.sessionPreset = .hd4K3840x2160

        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            print("Error: camera input")
            return
        }
        session.addInput(videoInput)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: detectionQueue)
        guard session.canAddOutput(videoOutput) else {
            print("Error: Unable to add video output")
            return
        }
        session.addOutput(videoOutput)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            view.layer.addSublayer(layer)
            self.videoPreviewLayer = layer
        }

        captureSession = session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    func stopSession() {
        trackedDarts.removeAll()
        onMain {
            self.throwHistory.removeAll()
            self.totalThrows.removeAll()
            self.lastScoreText = ""
            self.overlay = .init()
            self.isWaitingForRemoval = false
            self.isGameOver = false
        }
        captureSession?.stopRunning()
        resetTurnState()
    }

    func restartSession() {
        if let view = previewView, (captureSession == nil || captureSession?.isRunning == false) {
            startSession(in: view)
        }
    }

    // MARK: - UI hooks

    func pauseSession() { isPaused = true }
    func resumeSession() { isPaused = false }

    @MainActor
    func resetGame(to score: Int) {
        gameMode = score
        gameScore = score
        dartsThisLeg = 0
        throwHistory.removeAll()
        lastScoreText = "Game started. Score: \(score)"
        overlay = .init()
        isWaitingForRemoval = false
        isGameOver = false
        isPaused = false

        trackedDarts.removeAll()
        resetTurnState()
        restartSession()
        onDetectionUpdate?(nil, lastScoreText)
    }

    func setTorch(enabled: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
        } catch { print("Torch error: \(error)") }
    }

    func snapshotAnnotated() -> UIImage? {
        guard let preview = previewView else { return nil }
        UIGraphicsBeginImageContextWithOptions(preview.bounds.size, false, 0)
        defer { UIGraphicsEndImageContext() }
        preview.drawHierarchy(in: preview.bounds, afterScreenUpdates: true)
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    // MARK: - CaptureOutput

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        if isPaused || isGameOver { return }

        let now = CACurrentMediaTime()
        if now - lastDetectionTime < detectionInterval { return }
        lastDetectionTime = now

        // cooldown decay every processed frame
        if newDartCooldown > 0 { newDartCooldown -= 1 }

        guard let image = imageFromSampleBuffer(sampleBuffer) else { return }

        // 1) Detect board → crop
        processor?.detectDartboard(in: image) { [weak self] cropped in
            guard let self else { return }

            // 2) Darts on cropped image
            self.processor?.detectDartsAndAnnotate(in: cropped) { [weak self] _, observations in
                guard let self else { return }

                // Normalize observations to tracked darts (pre-filtered)
                let newDarts = self.filteredDarts(from: observations)
                self.mergeNewDetections(newDarts)

                // 3) Homography / visibility
                self.processor?.computeHomography(for: cropped) { [weak self] result in
                    guard let self else { return }
                    var boardVisible = true
                    if result?.usedSavedPoints == false {
                        self.boardVisibleStreak += 1
                        self.occludedStreak = 0
                    } else {
                        boardVisible = false
                        self.occludedStreak += 1
                        self.boardVisibleStreak = 0
                    }

                    // ---------- WAITING FOR REMOVAL (runs before any guard/return) ----------
                    if self.state == .waitingForRemoval {
                        // De-dup live detections for this decision (no H required)
                        let dedupedForRemoval = self.filterByDistanceNMS(self.trackedDarts, minDist: self.minCenterSeparation)
                        let centersForRemoval = dedupedForRemoval.map { CGPoint(x: $0.bbox.midX, y: $0.bbox.midY) }

                        // Consider "clear" if:
                        // 1) board is occluded (player in front), OR
                        // 2) there are no detections, OR
                        // 3) all detections are far from the last finalized dart positions
                        let farFromAll = centersForRemoval.allSatisfy { c in
                            self.lastTurnCenters.allSatisfy { prev in self.distance(prev, c) > self.newDartDistanceThreshold }
                        }
                        let isClearNow = (!boardVisible) || centersForRemoval.isEmpty || farFromAll

                        // Be a bit generous if occluded: count faster
                        if isClearNow {
                            self.framesSinceClear += (boardVisible ? 1 : 2)
                            if self.framesSinceClear >= self.framesNeededClear {
                                self.markBoardClearedReadyForNextTurn()
                            }
                        } else {
                            self.framesSinceClear = 0
                        }

                        // Keep UI minimal and stop processing while waiting-for-removal
                        self.onMain { self.overlay = DetectionOverlay() }
                        return
                    }
                    // -----------------------------------------------------------------------

                    // If occluded long enough mid-turn, finalize partial
                    print(self.occludedStreak)
                    print(self.currentTurn.isEmpty)
                    if self.occludedStreak >= self.occludedThreshold, !self.currentTurn.isEmpty {
                        self.onMain { self.finalizeTurnAndPublish() }
                        return
                    }

                    // Only proceed with scoring when the board is visible and we have H
                    guard boardVisible, let H = result?.H else {
                        // Optional: slim overlay update
                        if !self.currentTurn.isEmpty {
                            self.onMain {
                                self.overlay = DetectionOverlay(dartCenters: self.currentTurn.map { $0.center }, dartBoxes: [])
                            }
                        }
                        return
                    }
                    
                    self.beginTurnIfNeeded()

                    // TOP-3 by confidence → centers (normalized)
                    let deduped = self.filterByDistanceNMS(self.trackedDarts, minDist: self.minCenterSeparation)
                    let top = deduped.sorted { $0.confidence > $1.confidence }.prefix(3)
                    let centers = top.map { CGPoint(x: $0.bbox.midX, y: $0.bbox.midY) }

                    // Gate centers to board area (board-plane radius)
                    let transformed = self.processor?.transformToBoardplane(
                        H: H,
                        dartCoords: centers,
                        imageSize: cropped.size
                    ) ?? []

                    let gatedCenters: [CGPoint] = zip(centers, transformed).compactMap { (c, t) in
                        let r = hypot(t.x, t.y)
                        return (r <= self.maxBoardRadiusNorm && r >= self.minBoardRadiusNorm) ? c : nil
                    }

                    // Try to confirm a NEW dart (stabilize over a few frames)
                    if let newCenter = self.detectNewCenter(from: gatedCenters, confirmed: self.currentTurn.map { $0.center }) {

                        // If we're cooling down, skip until cooldown ends
                        guard self.newDartCooldown == 0 else {
                            // still refresh overlay with currentTurn + boxes
                            let overlay = DetectionOverlay(dartCenters: self.currentTurn.map { $0.center },
                                                           dartBoxes: top.map { $0.bbox })
                            self.onMain { self.overlay = overlay }
                            return
                        }

                        self.accumulateCandidate(center: newCenter)
                        if let confirmedCenter = self.popConfirmedCandidateIfStable() {

                            // Score ONLY this new dart
                            let one = self.processor?.transformToBoardplane(
                                H: H,
                                dartCoords: [confirmedCenter],
                                imageSize: cropped.size
                            ) ?? []

                            let (labels, points) = self.processor?.score(transformedDarts: one) ?? ([], 0)
                            let label = labels.first ?? "0"

                            let hit = DartHit(center: confirmedCenter, label: label, points: points)
                            self.beginTurnIfNeeded()
                            self.currentTurn.append(hit)
                            self.dartsThisLeg += 1

                            // start cooldown after a confirmed dart
                            self.newDartCooldown = self.cooldownFramesAfterConfirm

                            // Early finalize logic for bust or checkout mid-turn in scoring modes
                            if let _ = self.gameMode {
                                let partial = self.currentTurn.reduce(0) { $0 + $1.points }
                                let remaining = self.scoreAtTurnStart - partial
                                if remaining <= 0 {
                                    // Finish immediately on bust (< 0) or exact checkout (== 0)
                                    self.onMain { self.finalizeTurnAndPublish() }
                                    return
                                }
                            }

                            // Update overlay (show all confirmed)
                            let overlay = DetectionOverlay(
                                dartCenters: self.currentTurn.map { $0.center },
                                dartBoxes: top.map { $0.bbox }
                            )

                            // Incremental text (not final yet)
                            let incText = self.incrementalText()

                            self.onMain {
                                self.overlay = overlay
                                self.lastScoreText = incText
                                self.onDetectionUpdate?(nil, incText)
                            }

                            // If we reached 3 darts, finalize the turn
                            if self.currentTurn.count == 3 {
                                self.onMain { self.finalizeTurnAndPublish() }
                            }
                        }
                    } else {
                        // No new candidate this frame → just keep overlay up to date
                        let overlay = DetectionOverlay(
                            dartCenters: self.currentTurn.map { $0.center },
                            dartBoxes: top.map { $0.bbox }
                        )
                        self.onMain { self.overlay = overlay }
                    }
                }
            }
        }
    }

    // MARK: - Turn helpers

    private func beginTurnIfNeeded() {
        if state != .detecting {
            state = .detecting
            scoreAtTurnStart = gameScore
            currentTurn.removeAll()
            candidateNewDart = nil
        }
    }

    private func finalizeTurnAndPublish() {
        // Only pad with zeros if we reached 3 darts naturally, not when occluded
        let wasOccluded = occludedStreak >= occludedThreshold

        // Reset cooldown so stale candidates can't fire immediately next turn
        self.newDartCooldown = 0

        if !wasOccluded {
            while currentTurn.count < 3 {
                currentTurn.append(DartHit(center: .zero, label: "0", points: 0))
            }
        }

        let total = currentTurn.reduce(0) { $0 + $1.points }

        var newScoreText: String
        if let _ = gameMode {
            if gameScore - total < 0 {
                // Bust: whole turn invalid → revert to turn start
                gameScore = scoreAtTurnStart
                newScoreText = "Bust! Score remains: \(gameScore)"
            } else {
                gameScore -= total
                let dartCount = currentTurn.filter { $0.points > 0 || $0.label != "0" }.count
                let desc = "\(currentTurn.map { $0.label }.joined(separator: ", ")) = \(total)"
                let turnSummary = wasOccluded && dartCount < 3
                    ? "\(currentTurn.filter { $0.label != "0" }.map { $0.label }.joined(separator: ", ")) = \(total) (\(dartCount) darts)"
                    : desc

                throwHistory = [turnSummary]
                totalThrows.append(turnSummary)

                newScoreText = "Score: \(gameScore)\nLast: \(turnSummary)"
                if gameScore == 0 { newScoreText += "\nCongratulations, you finished the game!" }
            }
        } else {
            let dartCount = currentTurn.filter { $0.points > 0 || $0.label != "0" }.count
            let desc = currentTurn.map { $0.label }.joined(separator: ", ")
            let summary = wasOccluded && dartCount < 3 ? "\(total) (\(dartCount) darts)" : "\(total) (\(desc))"
            newScoreText = "Score: \(summary)"
        }

        // Save for editing
        lastFinalizedTurn = currentTurn
        lastFinalizedTurnStartScore = scoreAtTurnStart

        // Prepare next cycle
        trackedDarts.removeAll()
        candidateNewDart = nil

        // If the game is finished, halt detection and don't require board clearing
        if gameMode != nil && gameScore == 0 {
            isGameOver = true
            isPaused = true
            state = .waitingForBoard
            lastTurnCenters.removeAll()
            framesSinceClear = 0
            currentTurn.removeAll()
            isWaitingForRemoval = false
        } else {
            state = .waitingForRemoval
            lastTurnCenters = lastFinalizedTurn.map { $0.center }
            framesSinceClear = 0
            currentTurn.removeAll()
            isWaitingForRemoval = true
        }
        overlay = DetectionOverlay()
        lastScoreText = newScoreText
        onDetectionUpdate?(nil, newScoreText)
    }

    private func incrementalText() -> String {
        let labels = currentTurn.map { $0.label }.joined(separator: " • ")
        let partial = currentTurn.reduce(0) { $0 + $1.points }
        if let _ = gameMode {
            let remainingIfValid = (gameScore - partial) // temporary preview; final bust handled at turn end
            return "This turn: \(labels)  = \(partial)\n(Current est. remaining: \(remainingIfValid))"
        } else {
            return "This turn: \(labels)  = \(partial)"
        }
    }

    private func resetTurnState() {
        state = .waitingForBoard
        boardVisibleStreak = 0
        occludedStreak = 0
        currentTurn.removeAll()
        candidateNewDart = nil
        framesSinceClear = 0
    }

    // MARK: - Candidate / stabilization

    private func detectNewCenter(from centers: [CGPoint], confirmed: [CGPoint]) -> CGPoint? {
        for c in centers {
            if confirmed.allSatisfy({ distance($0, c) > newDartDistanceThreshold }) {
                return c
            }
        }
        return nil
    }

    private func accumulateCandidate(center: CGPoint) {
        if let cand = candidateNewDart {
            if distance(cand.center, center) <= newDartDistanceThreshold {
                candidateNewDart = (center: averaged(cand.center, center), frames: cand.frames + 1)
            } else {
                candidateNewDart = (center: center, frames: 1)
            }
        } else {
            candidateNewDart = (center: center, frames: 1)
        }
    }

    private func popConfirmedCandidateIfStable() -> CGPoint? {
        guard let cand = candidateNewDart, cand.frames >= stabilizationFramesNeeded else { return nil }
        let c = cand.center
        candidateNewDart = nil
        return c
    }

    private func filterByDistanceNMS(_ darts: [TrackedDart], minDist: CGFloat) -> [TrackedDart] {
        var result: [TrackedDart] = []
        for d in darts.sorted(by: { $0.confidence > $1.confidence }) {
            let c = CGPoint(x: d.bbox.midX, y: d.bbox.midY)
            let isFar = result.allSatisfy { r in
                let rc = CGPoint(x: r.bbox.midX, y: r.bbox.midY)
                return hypot(c.x - rc.x, c.y - rc.y) > minDist
            }
            if isFar { result.append(d) }
        }
        return result
    }
    
    // Merge new detections into the persistent list using IoU and confidence
    private func mergeNewDetections(_ newDetections: [TrackedDart], iouThreshold: CGFloat = 0.7) {
        guard !newDetections.isEmpty else { return }

        if trackedDarts.isEmpty {
            trackedDarts = newDetections
            return
        }

        for newD in newDetections {
            var matched = false
            for (i, existing) in trackedDarts.enumerated() {
                if iou(existing.bbox, newD.bbox) > iouThreshold {
                    // keep the higher-confidence box
                    if newD.confidence > existing.confidence {
                        trackedDarts[i] = newD
                    }
                    matched = true
                    break
                }
            }
            if !matched {
                trackedDarts.append(newD)
            }
        }
    }

    private func filteredDarts(from observations: [VNRecognizedObjectObservation]) -> [TrackedDart] {
        observations.compactMap { obs in
            guard let label = obs.labels.first?.identifier.lowercased(),
                  label.contains("dart") else { return nil }
            let bb = obs.boundingBox
            let conf = CGFloat(obs.confidence)

            let area = bb.width * bb.height
            guard conf >= dartConfidenceThreshold,
                  area >= minBoxAreaNorm, area <= maxBoxAreaNorm else { return nil }

            let ar = bb.width / max(0.0001, bb.height)
            guard aspectRatioRange.contains(ar) else { return nil }

            return TrackedDart(bbox: bb, confidence: conf, classId: 4)
        }
    }

    // MARK: - Edit support

    /// Replace the last finalized turn with user-edited hits (exactly 3),
    /// recompute from the STORED start-of-turn score, and update history.
    @MainActor
    func applyEditedLastTurn(_ edited: [DartHit]) {
        guard edited.count == 3,
              let startScore = lastFinalizedTurnStartScore else {
            return
        }

        let editedTotal = edited.reduce(0) { $0 + $1.points }
        var newText: String

        if let _ = gameMode {
            if startScore - editedTotal < 0 {
                gameScore = startScore
                newText = "Bust (edited). Score remains: \(gameScore)"
            } else {
                gameScore = startScore - editedTotal
                let desc = "\(edited.map { $0.label }.joined(separator: ", ")) = \(editedTotal)"

                if !totalThrows.isEmpty { _ = totalThrows.removeLast() }
                totalThrows.append(desc)
                throwHistory = [desc]

                newText = "Score: \(gameScore)\nLast (edited): \(desc)"
                if gameScore == 0 { newText += "\nCongratulations, you finished the game!" }
            }
        } else {
            let desc = edited.map { $0.label }.joined(separator: ", ")
            newText = "Score: \(editedTotal) (edited: \(desc))"
        }

        lastFinalizedTurn = edited
        lastFinalizedTurnStartScore = startScore

        // If edit leads to game finished, mark game over and avoid waiting-for-removal
        if gameMode != nil && gameScore == 0 {
            isGameOver = true
            isPaused = true
            state = .waitingForBoard
            isWaitingForRemoval = false
        }

        lastScoreText = newText
        onDetectionUpdate?(nil, newText)
    }

    /// Allow UI to manually advance if needed (e.g., banner button).
    func forceReadyForNextTurn() {
        markBoardClearedReadyForNextTurn()
    }
    
    func getLastFinalizedTurn() -> [DartHit] {
        return lastFinalizedTurn
    }

    // Called when removal is detected or user forces continue
    private func markBoardClearedReadyForNextTurn() {
        state = .waitingForBoard
        boardVisibleStreak = 0
        occludedStreak = 0
        lastTurnCenters.removeAll()
        trackedDarts.removeAll()
        framesSinceClear = 0
        onMain { self.isWaitingForRemoval = false }
    }

    // MARK: - Math

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        if i.isNull { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return sqrt(dx*dx + dy*dy)
    }

    private func averaged(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
    }

    // MARK: - Image helper

    private func imageFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ci = CIImage(cvPixelBuffer: pixel)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .right)
    }
}
