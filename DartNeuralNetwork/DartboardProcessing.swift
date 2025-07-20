import UIKit
import CoreML
import Vision
import simd

// Core class responsible for dartboard detection, dart detection, and scoring calculations
// Uses machine learning models and computer vision techniques to process images
class DartboardProcessing {

    // MARK: - Models and Calibration Properties
    let dartboardModel: VNCoreMLModel

    // Board-plane calibration coordinates (normalized; 6 points).
    var boardplaneCalibrationCoords: [CGPoint] = Array(repeating: CGPoint(x: -1, y: -1), count: 6)

    var savedCalibrationPoints: [CGPoint] = []

    // --- Scoring & Segmentation Properties (from get_scores.py) ---
    // Class names mapping (for YOLO output, if needed)
    let classNames: [Int: String] = [0: "calib_1", 1: "calib_2", 2: "calib_4", 3: "calib_3", 4: "dart"]

    // Dartboard measurements (in mm)
    // Note: these measurements come from your Python solution.
    let ring: CGFloat = 10.0          // width of the double and treble rings
    let bullseyeWire: CGFloat = 1.6     // width of the bullseye wires
    // let wire: CGFloat = 1.0          // width of other wires (not used here)

    // Scoring names and radii (normalized)
    // scoringNames: index 0 = DB (50), 1 = SB (25), 2 = S, 3 = T, 4 = S, 5 = D, 6 = miss
    let scoringNames: [String] = ["DB", "SB", "S", "T", "S", "D", "miss"]
    var scoringRadii: [CGFloat] = []
    // Segment angles (in degrees) and corresponding two possible numbers per segment.
    // (These values come directly from your Python solution.)
    let segmentAngles: [CGFloat] = [-9, 9, 27, 45, 63, -81, -63, -45, -27]
    let segmentNumbers: [[Int]] = [[6, 11],
                                   [10, 14],
                                   [15, 9],
                                   [2, 12],
                                   [17, 5],
                                   [19, 1],
                                   [7, 18],
                                   [16, 4],
                                   [8, 13]]

    // MARK: - Initialization
    init?() {
        do {
            // Replace 'dartboardDetector' with your actual generated model class.
            let dartboardMLModel = try dartboardDetector(configuration: MLModelConfiguration()).model
            self.dartboardModel = try VNCoreMLModel(for: dartboardMLModel)
        } catch {
            print("Error loading dartboard model:", error)
            return nil
        }

        // Compute scoring radii.
        // Original radii in mm: [0, 6.35, 15.9, 107.4 - ring, 107.4, 170.0 - ring, 170.0]
        // Adjust bullseye radii by adding half the bullseye wire width to indices 1 and 2.
        let rawRadii: [CGFloat] = [0,
                                   6.35,
                                   15.9,
                                   107.4 - ring,
                                   107.4,
                                   170.0 - ring,
                                   170.0]
        scoringRadii = rawRadii.enumerated().map { (index, value) -> CGFloat in
            var v = value
            if index == 1 || index == 2 {
                v += bullseyeWire / 2.0
            }
            // Normalize by dividing by the dartboard diameter (451 mm)
            return v / 451.0
        }

        // Compute boardplane calibration coordinates using the last scoring radius (h)
        // (These calculations mirror the Python code.)
        let h = scoringRadii.last!  // normalized outer radius (~0.377)
        // For 20 & 3:
        let a1 = h * cos(81 * .pi / 180)
        let o1 = sqrt(max(0, h * h - a1 * a1))
        boardplaneCalibrationCoords[0] = CGPoint(x: 0.5 - a1, y: 0.5 - o1)
        boardplaneCalibrationCoords[1] = CGPoint(x: 0.5 + a1, y: 0.5 + o1)
        // For 11 & 6:
        let a2 = h * cos(-9 * .pi / 180)
        let o2 = sqrt(max(0, h * h - a2 * a2))
        boardplaneCalibrationCoords[2] = CGPoint(x: 0.5 - a2, y: 0.5 + o2)
        boardplaneCalibrationCoords[3] = CGPoint(x: 0.5 + a2, y: 0.5 - o2)
        // For 9 & 15:
        let a3 = h * cos(27 * .pi / 180)
        let o3 = sqrt(max(0, h * h - a3 * a3))
        boardplaneCalibrationCoords[4] = CGPoint(x: 0.5 - a3, y: 0.5 - o3)
        boardplaneCalibrationCoords[5] = CGPoint(x: 0.5 + a3, y: 0.5 + o3)
    }

    // MARK: - Dartboard Detection & Cropping
    // Uses the dartboard detection ML model to locate and crop the dartboard in an image
    func detectDartboard(in image: UIImage, completion: @escaping (UIImage) -> Void) {
        let request = VNCoreMLRequest(model: dartboardModel) { request, error in
            if let error = error {
                print("Dartboard detection error:", error)
                completion(image)
                return
            }
            guard let results = request.results as? [VNRecognizedObjectObservation],
                  let first = results.first else {
                print("No dartboard detected.")
                completion(image)
                return
            }
            let boundingBox = first.boundingBox

            // Convert normalized bounding box to pixel coordinates.
            let width = image.size.width
            let height = image.size.height
            let x = round(boundingBox.origin.x * width)
            let y = round((1 - boundingBox.origin.y - boundingBox.height) * height)
            let w = round(boundingBox.width * width)
            let h = round(boundingBox.height * height)
            let cropRect = CGRect(x: x, y: y, width: w, height: h)
            let croppedImage = self.resizeImage(self.cropImage(image, with: cropRect), to: CGSize(width: 800, height: 800))
            completion(croppedImage)
        }
        request.imageCropAndScaleOption = .scaleFill
        guard let cgImage = image.cgImage else {
            completion(image)
            return
        }
        let handler = VNImageRequestHandler(cgImage: cgImage,
                                            orientation: CGImagePropertyOrientation(image.imageOrientation),
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("Error performing dartboard detection:", error)
            completion(image)
        }
    }

    // MARK: - Dart Detection with Annotation & Extraction
    /// Uses the dart detection model (e.g. bestSmall) to detect darts and returns an annotated image and the detection observations.
    func detectDartsAndAnnotate(in image: UIImage, completion: @escaping (UIImage, [VNRecognizedObjectObservation]) -> Void) {
        do {
            // Replace 'bestSmall' with your actual dart detection model.
            let dartMLModel = try _456Medium60(configuration: MLModelConfiguration()).model
            let dartModel = try VNCoreMLModel(for: dartMLModel)
            let request = VNCoreMLRequest(model: dartModel) { request, error in
                if let error = error {
                    print("Dart detection error:", error)
                    completion(image, [])
                    return
                }
                guard let observations = request.results as? [VNRecognizedObjectObservation] else {
                    print("No detections returned.")
                    completion(image, [])
                    return
                }
                let filteredObservations = observations.filter { $0.confidence >= 0.2 }
                let annotatedImage = self.annotateDetections(on: image, observations: filteredObservations)
                completion(annotatedImage, filteredObservations)
            }
            request.imageCropAndScaleOption = .scaleFill
            guard let cgImage = image.cgImage else {
                completion(image, [])
                return
            }
            let handler = VNImageRequestHandler(cgImage: cgImage,
                                                orientation: CGImagePropertyOrientation(image.imageOrientation),
                                                options: [:])
            try handler.perform([request])
        } catch {
            print("Error detecting darts:", error)
            completion(image, [])
        }
    }

    // Draws bounding boxes and labels around detected objects in the image
    func annotateDetections(on image: UIImage, observations: [VNRecognizedObjectObservation]) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let cgContext = context.cgContext
            let width = image.size.width
            let height = image.size.height
            for obs in observations {
                guard let label = obs.labels.first?.identifier.lowercased() else { continue }
                let bbox = obs.boundingBox
                let rect = CGRect(x: bbox.origin.x * width,
                                  y: (1 - bbox.origin.y - bbox.height) * height,
                                  width: bbox.width * width,
                                  height: bbox.height * height)
                //print("Detection: \(label) - BBox (normalized): \(bbox)")

                let strokeColor: UIColor = label.contains("dart") ? .red : .blue
                cgContext.setStrokeColor(strokeColor.cgColor)
                cgContext.setLineWidth(2)
                cgContext.stroke(rect)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: strokeColor
                ]
                let textPoint = CGPoint(x: rect.origin.x, y: rect.origin.y - 14)
                label.draw(at: textPoint, withAttributes: attributes)
            }
        }
    }

    // MARK: - Homography Computation
    func findHomography(calibrationCoords: [CGPoint],
                        boardplaneCalibrationCoords: [CGPoint],
                        imageSize: CGSize) -> simd_float3x3? {
        // Only include calibration points that have valid normalized coordinates.
        let validIndices = calibrationCoords.enumerated().compactMap { (index, point) -> Int? in
            return (point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1) ? index : nil
        }

        guard validIndices.count >= 4 else {
            print("Not enough valid calibration points")
            return nil
        }
        let validSrc = validIndices.map { calibrationCoords[$0] }
        let validDst = validIndices.map { boardplaneCalibrationCoords[$0] }
        let scaledSrc = validSrc.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) }
        let scaledDst = validDst.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) }

        //print("\n=== Homography Input Points ===")
        //print("📌 Source Points (Detected Calibration - Scaled to \(imageSize.width)x\(imageSize.height)):")
        for (i, point) in scaledSrc.enumerated() {
            //print("Src \(i): (\(point.x), \(point.y))")
        }
        //print("\n📌 Destination Points (Reference Board Plane - Scaled to \(imageSize.width)x\(imageSize.height)):")
        for (i, point) in scaledDst.enumerated() {
            //print("Dst \(i): (\(point.x), \(point.y))")
        }
        //print("==============================\n")

        let srcNSValues = scaledSrc.map { NSValue(cgPoint: $0) }
        let dstNSValues = scaledDst.map { NSValue(cgPoint: $0) }
        let H_matrix = HomographyHelper.findHomography(fromPoints: srcNSValues, toPoints: dstNSValues)
        return H_matrix
    }

    // MARK: - Transformation to Board-Plane (Step 4)
    /// Transforms an array of dart coordinates (in normalized image coordinates)
    /// into board-plane coordinates (normalized) using the homography matrix.
    func transformToBoardplane(H: simd_float3x3, dartCoords: [CGPoint], imageSize: CGSize) -> [CGPoint] {
        var transformed: [CGPoint] = []
        for point in dartCoords {
            // Convert normalized point to pixel coordinates.
            let pixelPoint = CGPoint(x: point.x * imageSize.width, y: point.y * imageSize.height)
            let vector = simd_float3(Float(pixelPoint.x), Float(pixelPoint.y), 1.0)
            let result = H * vector
            guard result.z != 0 else {
                transformed.append(point)
                continue
            }
            // Get transformed pixel coordinates.
            let transformedPixel = CGPoint(x: CGFloat(result.x / result.z), y: CGFloat(result.y / result.z))
            // Convert back to normalized board-plane coordinates.
            let normPoint = CGPoint(x: transformedPixel.x / imageSize.width, y: transformedPixel.y / imageSize.height)
            transformed.append(normPoint)
        }
        return transformed
    }

    // MARK: - Dart Scoring (Step 5)
    /// Computes the dart scores using transformed dart coordinates (normalized board-plane space).
    /// Returns an array of dart labels (e.g., "T20", "SB", etc.) and the total score.
    func score(transformedDarts: [CGPoint]) -> (dartLabels: [String], totalScore: Int) {
        var dartLabels: [String] = Array(repeating: "", count: transformedDarts.count)
        var totalScore = 0
        let epsilon: CGFloat = 0.00001

        // Process each dart.
        for (i, dart) in transformedDarts.enumerated() {
            // Avoid division-by-zero by nudging x if needed.
            var x = dart.x
            if abs(x - 0.5) < CGFloat.ulpOfOne {
                x += epsilon
            }
            let y = dart.y

            // Compute the angle (in degrees) relative to the center (0.5, 0.5)
            // Using arctan((y - 0.5)/(x - 0.5)) as in Python.
            var angleDeg = CGFloat(atan((y - 0.5) / (x - 0.5))) * 180 / .pi
            // Floor if positive; ceil if negative.
            angleDeg = angleDeg > 0 ? floor(angleDeg) : ceil(angleDeg)

            // Determine possible segment numbers.
            var possibleNumbers: [Int] = []
            if abs(angleDeg) >= 81 {
                possibleNumbers = [3, 20]
            } else {
                // Filter segmentAngles for those <= angleDeg and take the maximum.
                let candidates = segmentAngles.filter { $0 <= angleDeg }
                if let maxCandidate = candidates.max(), let idx = segmentAngles.firstIndex(of: maxCandidate) {
                    possibleNumbers = segmentNumbers[idx]
                } else {
                    // Fallback if no candidate found.
                    possibleNumbers = [3, 20]
                }
            }

            // Decide which coordinate to use for disambiguation.
            // If possibleNumbers equals [6, 11] then use the x-coordinate (index 0); otherwise use y (index 1).
            let coordIndex = (possibleNumbers == [6, 11]) ? 0 : 1
            // Since our dart coordinate is 2D, use x if coordIndex == 0, else y.
            let coordValue = (coordIndex == 0) ? dart.x : dart.y
            let number = (coordValue > 0.5) ? possibleNumbers[0] : possibleNumbers[1]

            // Compute distance from center.
            let dx = dart.x - 0.5
            let dy = dart.y - 0.5
            let distance = sqrt(dx * dx + dy * dy)

            // Determine the scoring region.
            // Mimic the Python logic by finding the last index where distance > scoringRadii.
            var regionIndex = 0
            for (idx, radius) in scoringRadii.enumerated() {
                if distance > radius {
                    regionIndex = idx
                }
            }
            // Use the region to look up the scoring name.
            let region = scoringNames[regionIndex]

            // Define scores for each region.
            // "DB": 50, "SB": 25, "S": single, "T": triple, "D": double, "miss": 0.
            var label = ""
            var dartScore = 0
            switch region {
            case "DB":
                label = "DB"
                dartScore = 50
            case "SB":
                label = "SB"
                dartScore = 25
            case "S":
                label = "S" + String(number)
                dartScore = number
            case "T":
                label = "T" + String(number)
                dartScore = number * 3
            case "D":
                label = "D" + String(number)
                dartScore = number * 2
            default:
                label = "miss"
                dartScore = 0
            }
            dartLabels[i] = label
            totalScore += dartScore
        }
        return (dartLabels, totalScore)
    }

    // MARK: - Pipeline Function (Integrated Steps)
    /// Runs the full pipeline:
    /// 1. Detects and annotates darts.
    /// 2. Computes homography from calibration points.
    /// 3. Transforms dart centers from image space into board-plane coordinates.
    /// 4. Computes scores (labels and total score) as in get_scores.py.
    /// 5. Overlays the score labels on the annotated image.
    func runPipeline(on image: UIImage, completion: @escaping (UIImage) -> Void) {
        // Preserve original image for homography/calibration.
        let originalImage = image
        detectDartsAndAnnotate(in: image) { annotatedImage, dartObservations in

            // --- Filter out calibration detections ---
            let dartObservationsFiltered = dartObservations.filter { obs in
                if let label = obs.labels.first?.identifier.lowercased() {
                    return label == "dart"
                }
                return false
            }

            // Extract dart centers from filtered detections (using normalized bbox centers).
            var dartCenters: [CGPoint] = []
            for obs in dartObservationsFiltered {
                let bbox = obs.boundingBox
                let center = CGPoint(x: bbox.origin.x + bbox.width/2,
                                     y: bbox.origin.y + bbox.height/2)
                dartCenters.append(center)
            }

            // Compute homography using calibration points.
            self.computeHomography(for: originalImage) { H in
                guard let H = H else {
                    print("Homography unavailable – skipping score transformation.")
                    completion(annotatedImage)
                    return
                }
                // Transform dart centers to board-plane coordinates.
                let transformedDarts = self.transformToBoardplane(H: H, dartCoords: dartCenters, imageSize: originalImage.size)
                // Compute dart scores.
                let (labels, total) = self.score(transformedDarts: transformedDarts)
                print("Dart Labels: \(labels)")
                print("Total Score: \(total)")

                // Annotate the image with score labels.
                let finalImage = self.annotateScores(on: annotatedImage, labels: labels, positions: transformedDarts, imageSize: originalImage.size)
                completion(finalImage)
            }
        }
    }


    /// Helper to compute homography using calibration points detected in the image.
    func computeHomography(for image: UIImage, using calibrationPoints: [CGPoint]? = nil, completion: @escaping (simd_float3x3?) -> Void) {
        detectCalibrationPoints(in: image) { calibrationPoints in
            let pointsToUse: [CGPoint]
            if calibrationPoints.count < 4 {
                print("Not enough calibration points detected: \(calibrationPoints.count)")
                print("Using stored calibration points instead.")
                pointsToUse = self.savedCalibrationPoints
            } else {
                pointsToUse = calibrationPoints
            }
            let boardplanePoints = Array(self.boardplaneCalibrationCoords.prefix(pointsToUse.count))
            if let H = self.findHomography(calibrationCoords: pointsToUse,
                                           boardplaneCalibrationCoords: boardplanePoints,
                                           imageSize: image.size) {
                //print("Homography Matrix computed successfully:\n\(H)")
                completion(H)
            } else {
                print("Homography computation failed.")
                completion(nil)
            }
        }
    }

    /// Detects calibration points using the dart detection model.
    func detectCalibrationPoints(in image: UIImage, completion: @escaping ([CGPoint]) -> Void) {
            do {
                let dartMLModel = try _456Medium60(configuration: MLModelConfiguration()).model
                let dartModel = try VNCoreMLModel(for: dartMLModel)
                let request = VNCoreMLRequest(model: dartModel) { request, error in
                    var calibrationPoints: [CGPoint?] = [nil, nil, nil, nil] // For calib_1, calib_2, calib_3, calib_4

                    if let observations = request.results as? [VNRecognizedObjectObservation] {
                        for obs in observations {
                            if let label = obs.labels.first?.identifier.lowercased() {
                                let bbox = obs.boundingBox
                                let center = CGPoint(x: bbox.origin.x + bbox.width / 2,
                                                     y: bbox.origin.y + bbox.height / 2)
                                //print("Detected: \(label) at center: \(center)")
                                // Map detections to calibration points.
                                if label.contains("calib_1") { calibrationPoints[0] = center }
                                if label.contains("calib_2") { if calibrationPoints[1] == nil { calibrationPoints[1] = center } }
                                if label.contains("calib_3") { calibrationPoints[2] = center }
                                if label.contains("calib_4") { calibrationPoints[3] = center }
                            }
                        }
                    }

                    //print("Final Calibration Points:")
                    for (i, point) in calibrationPoints.enumerated() {
                        if let p = point {
                            //print("calib_\(i+1): (\(p.x), \(p.y))")
                        } else {
                            //print("⚠️ Missing calib_\(i+1)")
                        }
                    }

                    let finalPoints = calibrationPoints.compactMap { $0 }
                    // Save the calibration points if enough are detected.
                    if finalPoints.count >= 4 {
                        self.savedCalibrationPoints = finalPoints
                    }
                    completion(finalPoints)
                }

                request.imageCropAndScaleOption = .scaleFill
                guard let cgImage = image.cgImage else {
                    completion([])
                    return
                }
                let handler = VNImageRequestHandler(cgImage: cgImage,
                                                    orientation: CGImagePropertyOrientation(image.imageOrientation),
                                                    options: [:])
                try handler.perform([request])
            } catch {
                print("Error detecting calibration points:", error)
                completion([])
            }
    }

    // MARK: - Annotate Scores on Image
    /// Draws the dart score labels at the given positions (transformed board-plane positions scaled back to pixel coordinates).
    func annotateScores(on image: UIImage, labels: [String], positions: [CGPoint], imageSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            for (i, pos) in positions.enumerated() {
                let scoreText = labels[i]
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 16),
                    .foregroundColor: UIColor.green
                ]
                // Convert normalized board-plane position back to pixel coordinates.
                let pixelPoint = CGPoint(x: pos.x * imageSize.width, y: pos.y * imageSize.height)
                let textSize = scoreText.size(withAttributes: attributes)
                let textOrigin = CGPoint(x: pixelPoint.x - textSize.width / 2, y: pixelPoint.y - textSize.height / 2)
                scoreText.draw(at: textOrigin, withAttributes: attributes)
            }
        }
    }

    // MARK: - Basic Image Helpers
    func cropImage(_ image: UIImage, with cropRect: CGRect) -> UIImage {
        // First, fix the image orientation.
        let fixedImage = fixOrientation(of: image)

        // Ensure we have a CGImage.
        guard let cgImage = fixedImage.cgImage else {
            print("Failed to retrieve CGImage.")
            return image
        }

        // Convert the crop rectangle from points to pixels using the image's scale factor.
        let scale = fixedImage.scale
        let pixelCropRect = CGRect(x: cropRect.origin.x * scale,
                                   y: cropRect.origin.y * scale,
                                   width: cropRect.size.width * scale,
                                   height: cropRect.size.height * scale)

        // Crop the CGImage using the pixel-based rectangle.
        guard let croppedCGImage = cgImage.cropping(to: pixelCropRect) else {
            print("Cropping failed, returning original image.")
            return image
        }

        // Create and return a new UIImage from the cropped CGImage with the original scale and orientation.
        return UIImage(cgImage: croppedCGImage, scale: scale, orientation: fixedImage.imageOrientation)
    }


    // Resizes an image to the specified dimensions while maintaining aspect ratio
    func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return resizedImage
    }

    // Corrects the orientation of an image to ensure proper processing
    func fixOrientation(of image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return normalizedImage
    }
}

extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
