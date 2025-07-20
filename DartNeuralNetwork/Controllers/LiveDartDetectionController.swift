import AVFoundation
import UIKit
import Vision

// Define a simple structure for a tracked dart.
struct TrackedDart {
    var bbox: CGRect      // The normalized bounding box (as returned by Vision)
    var confidence: CGFloat
    var classId: Int
}

class LiveDartDetectionController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, ObservableObject {
    var captureSession: AVCaptureSession!
    var videoPreviewLayer: AVCaptureVideoPreviewLayer!
    let detectionQueue = DispatchQueue(label: "com.yourapp.dartDetectionQueue")
    
    // Create your processor instance (which contains your Vision and scoring pipeline)
    var processor: DartboardProcessing? = DartboardProcessing()

    // For throttling detections
    var lastDetectionTime: TimeInterval = 0
    let detectionInterval: TimeInterval = 1  // adjust as needed
    
    var throwDelay: TimeInterval = 7   // delay in seconds
    var lastThrowFinalizedTime: TimeInterval = 0
    
    // Callback to update UI with annotated image or score information.
    var onDetectionUpdate: ((UIImage, String) -> Void)?
    
    // Weak reference to preview view for restarting session.
    weak var previewView: UIView?
    
    // Debug flag (if true, shows the cropped image for debugging instead of full pipeline)
    var debugShowCroppedImage: Bool = false
    
    // Persistent dart tracking list (accumulating detections over time)
    var trackedDarts: [TrackedDart] = []
    
    // Game-related properties.
    var gameMode: Int? = nil       // e.g., 301 or 501; nil means no game mode
    var gameScore: Int = 0         // current game score
    var throwHistory: [String] = []  // holds descriptions of the last three throws
    var totalThrows: [String] = []
    var lastScoreText: String = ""

    
    // MARK: - Session Management
    
    func startSession(in view: UIView) {
        self.previewView = view  // save reference
        
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .hd4K3840x2160

        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoInput)
        else {
            print("Error accessing camera input")
            return
        }
        captureSession.addInput(videoInput)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings =
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: detectionQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            print("Error: Unable to add video output")
            return
        }
        captureSession.addOutput(videoOutput)

        // Setup preview layer on main thread.
        videoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        videoPreviewLayer.videoGravity = .resizeAspectFill
        videoPreviewLayer.frame = view.bounds
        DispatchQueue.main.async {
            view.layer.addSublayer(self.videoPreviewLayer)
        }
        
        // Start the session on a background thread.
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }
    
    func stopSession() {
        self.trackedDarts.removeAll()
        self.lastScoreText = ""
        throwHistory = []
        totalThrows = []
        captureSession.stopRunning()
    }
    
    func restartSession() {
        if let view = previewView {
            if captureSession == nil || !captureSession.isRunning {
                startSession(in: view)
            }
        }
    }
    
    // MARK: - Dart Merging Helpers
    
    // Compute Intersection over Union (IoU) for two CGRects.
    func iou(_ rectA: CGRect, _ rectB: CGRect) -> CGFloat {
        let intersection = rectA.intersection(rectB)
        if intersection.isNull {
            return 0
        }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = rectA.width * rectA.height + rectB.width * rectB.height - intersectionArea
        return intersectionArea / unionArea
    }
    
    // Merge new detections into trackedDarts.
    // Maybe change this value depending on results
    func mergeNewDetections(newDetections: [TrackedDart], iouThreshold: CGFloat = 0.7) {
        for newDetection in newDetections {
            var matched = false
            for (index, existing) in trackedDarts.enumerated() {
                let iouValue = iou(existing.bbox, newDetection.bbox)
                if iouValue > iouThreshold {
                    // If new detection has higher confidence, update.
                    if newDetection.confidence > existing.confidence {
                        trackedDarts[index] = newDetection
                    }
                    matched = true
                    break
                }
            }
            if !matched {
                trackedDarts.append(newDetection)
            }
        }
    }
    
    // MARK: - Capture Output
    
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let currentTime = CACurrentMediaTime()
        
        if currentTime - lastThrowFinalizedTime < throwDelay {
                return
            }
        
        if currentTime - lastDetectionTime < detectionInterval {
            return
        }
        lastDetectionTime = currentTime

        guard let image = self.imageFromSampleBuffer(sampleBuffer) else { return }
        
        // First, run dartboard detection to crop the image.
        processor?.detectDartboard(in: image) { croppedImage in
            
            // Debug branch: show cropped image if flag is set.
            if self.debugShowCroppedImage {
                DispatchQueue.main.async {
                    self.onDetectionUpdate?(croppedImage, "Debug: Cropped Image")
                }
                // Optionally save the debug image.
                UIImageWriteToSavedPhotosAlbum(croppedImage, nil, nil, nil)
                return  // Skip the rest of the pipeline.
            }
            
            // Run dart detection on the cropped image.
            self.processor?.detectDartsAndAnnotate(in: croppedImage) { annotatedImage, observations in
                
                // Convert Vision observations into our TrackedDart structure,
                // but only add those whose label contains "dart".
                var newDarts: [TrackedDart] = []
                for obs in observations {
                    if let label = obs.labels.first?.identifier.lowercased(), label.contains("dart") {
                        let bbox = obs.boundingBox  // normalized bbox
                        let confidence = CGFloat(obs.confidence)
                        let dart = TrackedDart(bbox: bbox, confidence: confidence, classId: 4)
                        newDarts.append(dart)
                    }
                }

                // Merge new detections with our persistent tracked darts.
                self.mergeNewDetections(newDetections: newDarts)
                
                // Run calibration detection on the cropped image.
                self.processor?.detectCalibrationPoints(in: croppedImage) { calibPoints in
                    if calibPoints.count < 3 {
                        self.processor?.computeHomography(for: croppedImage) { H in
                            guard let H = H else {
                                DispatchQueue.main.async {
                                    self.onDetectionUpdate?(annotatedImage, "Error: Homography failed")
                                }
                                return
                            }
                            
                            // Use only the top three tracked darts by confidence.
                            let topDarts = self.trackedDarts.sorted { $0.confidence > $1.confidence }.prefix(3)
                            var dartCenters: [CGPoint] = []
                            for dart in topDarts {
                                let center = CGPoint(x: dart.bbox.origin.x + dart.bbox.width / 2,
                                                     y: dart.bbox.origin.y + dart.bbox.height / 2)
                                dartCenters.append(center)
                            }
                            
                            let transformed = self.processor?.transformToBoardplane(H: H,
                                                                                     dartCoords: dartCenters,
                                                                                     imageSize: croppedImage.size) ?? []
                            let (labels, totalScore) = self.processor?.score(transformedDarts: transformed) ?? ([], 0)
                            
                            var newScoreText = ""
                            
                            // If game mode is active, update game score.
                            if let _ = self.gameMode {
                                if self.gameScore - totalScore < 0 {
                                    newScoreText = "Bust! Throw not counted. Score remains: \(self.gameScore)"
                                } else {
                                    self.gameScore -= totalScore
                                    // Clear the previous throw history and add the current throw only.
                                    let currentThrowDescription = "\(labels.joined(separator: ", ")) scored \(totalScore)"
                                    self.throwHistory = [currentThrowDescription]
                                    self.totalThrows.append(currentThrowDescription)
                                    print("Total Throw History: \(self.totalThrows)")
                                    newScoreText = "Score: \(self.gameScore)\nLast throw: \(self.throwHistory.joined(separator: " | "))"
                                    if self.gameScore == 0 {
                                        newScoreText += "\nCongratulations, you finished the game!"
                                    }
                                }
                            } else {
                                // Non-game mode: just show the computed score.
                                newScoreText = "Score: \(totalScore) (\(labels.joined(separator: ", ")))"
                            }
                            
                            self.lastThrowFinalizedTime = CACurrentMediaTime()
                            
                            self.lastScoreText = newScoreText
                            
                            DispatchQueue.main.async {
                                self.onDetectionUpdate?(annotatedImage, newScoreText)
                            }
                            
                            // Clear tracked darts for next throw.
                            self.trackedDarts.removeAll()
                        }
                    } else {
                        // If calibration points are sufficient, continue showing the last computed score.
                        DispatchQueue.main.async {
                            self.onDetectionUpdate?(annotatedImage, self.lastScoreText)
                        }
                    }
                }

            }
        }
    }

    
    // MARK: - Image Conversion Helper
    
    func imageFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        // Adjust the orientation as needed; .right is often correct for portrait camera output.
        return UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .right)
    }
}
