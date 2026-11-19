import SwiftUI
import simd

/// Draws what the detector sees over the full-screen camera view: board rings and sector lines
/// through the current homography, calibration points, raw dart detections with their
/// confidence, tracks that may become darts, and confirmed darts. A tool for judging the model
/// on a real board.
struct DetectorDebugOverlay: View {
    @ObservedObject var model: DetectorDebugModel

    var body: some View {
        Canvas { context, size in
            guard let snapshot = model.snapshot else { return }
            draw(snapshot, in: &context, mapping: ImageToView(image: snapshot.imageSize, view: size))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    private static let ring = Color.white.opacity(0.85)
    private static let calibrationOK = Color(hex: 0x2BD27A)
    private static let calibrationBad = Color(hex: 0xFF4D4F)
    private static let raw = Color(hex: 0xF2A93B)
    private static let track = Color(hex: 0x5AC8FA)
    private static let dart = Color(hex: 0x0E7AFE)

    private func draw(_ s: DetectorSnapshot, in context: inout GraphicsContext, mapping m: ImageToView) {
        // Region the model looked at.
        if s.crop.width < s.imageSize.width - 1 || s.crop.height < s.imageSize.height - 1 {
            context.stroke(Path(m.rect(s.crop)), with: .color(.white.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        }

        if let board = s.boardToImage {
            // Rings and sector lines, projected from board millimetres.
            for radius in BoardGeometry.ringRadii.map({ $0 * BoardGeometry.doubleOuterMM }) {
                var path = Path()
                for i in 0...96 {
                    let a = Double(i) / 96 * 2 * .pi
                    guard let p = board.apply(SIMD2(cos(a), sin(a)) * radius) else { continue }
                    i == 0 ? path.move(to: m.point(p)) : path.addLine(to: m.point(p))
                }
                context.stroke(path, with: .color(Self.ring), lineWidth: 1)
            }
            for index in 0..<20 {
                let a = (Double(index) * 18 - 9) * .pi / 180
                let direction = SIMD2(sin(a), -cos(a))
                guard let inner = board.apply(direction * BoardGeometry.outerBullRadius * BoardGeometry.doubleOuterMM),
                      let outer = board.apply(direction * BoardGeometry.doubleOuterMM) else { continue }
                var path = Path()
                path.move(to: m.point(inner))
                path.addLine(to: m.point(outer))
                context.stroke(path, with: .color(Self.ring.opacity(0.7)), lineWidth: 1)
            }
            // Numbers, so a wrong rotation is obvious.
            for number in Segment.boardOrder {
                let a = BoardGeometry.angle(of: number) * .pi / 180
                guard let p = board.apply(SIMD2(sin(a), -cos(a)) * BoardGeometry.doubleOuterMM * 1.12) else { continue }
                context.draw(Text("\(number)").font(.system(size: 11, weight: .bold).width(.condensed)).foregroundColor(.white),
                             at: m.point(p))
            }
            // Where the calibration points should be.
            for p in s.expectedCalibration {
                let c = m.point(p)
                context.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)),
                               with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
        }

        // Calibration points found in this frame.
        for point in s.calibration {
            let c = m.point(point.pixel)
            let color = point.agrees ? Self.calibrationOK : Self.calibrationBad
            context.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(color))
            context.draw(Text("\(point.classIndex + 1)").font(.system(size: 10, weight: .heavy).monospacedDigit()).foregroundColor(color),
                         at: CGPoint(x: c.x + 9, y: c.y - 9))
        }

        // Raw dart detections with confidence (strong ones at the single-frame threshold or more).
        for d in s.darts {
            let c = m.point(d.pixel)
            let strong = d.confidence >= SingleImageResult.singleFrameDartConfidence
            let r: CGFloat = strong ? 6 : 4.5
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(Self.raw.opacity(strong ? 1 : 0.75)), lineWidth: strong ? 2 : 1.2)
            context.draw(Text(String(format: "%.2f", d.confidence))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundColor(Self.raw),
                         at: CGPoint(x: c.x, y: c.y + 14))
        }

        // Tracks (candidate darts) with their summed evidence.
        for t in s.tracks {
            let c = m.point(t.pixel)
            let color = t.isBackground ? Color.gray : Self.track
            context.stroke(Path(ellipseIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)),
                           with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: t.isBackground ? [3, 3] : []))
            context.draw(Text(t.isBackground ? "bg" : String(format: "%.1f", t.evidence))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundColor(color),
                         at: CGPoint(x: c.x + 20, y: c.y))
        }

        // Darts already reported: this visit (blue) and closed visits still in the board (grey).
        for (darts, fill) in [(s.visitDarts, Self.dart), (s.oldDarts, Color.gray)] {
            for d in darts {
                let c = m.point(d.pixel)
                context.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.white))
                context.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(fill))
                let label = Text(d.label).font(.system(size: 12, weight: .heavy).width(.condensed)).foregroundColor(.white)
                let resolved = context.resolve(label)
                let size = resolved.measure(in: CGSize(width: 100, height: 30))
                let box = CGRect(x: c.x - size.width / 2 - 5, y: c.y - 30, width: size.width + 10, height: size.height + 4)
                context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(fill))
                context.draw(resolved, at: CGPoint(x: box.midX, y: box.midY))
            }
        }
    }
}

/// Numbers and legend shown with the overlay.
struct DetectorDebugPanel: View {
    @ObservedObject var model: DetectorDebugModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let s = model.snapshot {
                row(lockText(s))
                row("\(s.calibration.filter(\.agrees).count)/12 points" + (s.lockRMSErrorMM.map { String(format: " · rms %.1f mm", $0) } ?? ""))
                row(String(format: "%.0f ms · %.1f fps", s.inferenceMilliseconds, s.framesPerSecond)
                    + " · \(Int(s.crop.width))×\(Int(s.crop.height))")
                row(phaseText(s.phase) + " · \(s.visitDarts.count) dart\(s.visitDarts.count == 1 ? "" : "s")"
                    + (s.oldDarts.isEmpty ? "" : " · \(s.oldDarts.count) to pull"))
                HStack(spacing: 8) {
                    legend("cal", Color(hex: 0x2BD27A))
                    legend("raw", Color(hex: 0xF2A93B))
                    legend("track", Color(hex: 0x5AC8FA))
                    legend("dart", Color(hex: 0x0E7AFE))
                }
                .padding(.top, 2)
            } else {
                row("Waiting for the model…")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    private func row(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold).monospacedDigit()).lineLimit(1)
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2.weight(.semibold))
        }
    }

    private func lockText(_ s: DetectorSnapshot) -> String {
        switch s.frameUse {
        case .forming(let streak): return "Locking \(streak)/\(DetectorTuning.lockFramesNeeded)"
        case .usable(let clear): return clear ? "Locked · clear view" : "Locked · partly hidden"
        case .occluded: return s.boardToImage == nil ? "No lock" : "Locked · hidden"
        case .moved: return "Camera moved"
        case .noBoard: return "No board"
        }
    }

    private func phaseText(_ phase: MultiFrameTracker.Phase) -> String {
        switch phase {
        case .throwing: return "Throwing"
        case .awaitingRemoval: return "Pull darts"
        case .resetBarrier: return "Clear board"
        }
    }
}

/// Maps upright image pixels to view points the way the preview shows them (aspect fill, centred).
struct ImageToView {
    let scale: Double
    let offset: SIMD2<Double>

    init(image: CGSize, view: CGSize) {
        let s = max(view.width / max(image.width, 1), view.height / max(image.height, 1))
        scale = s
        offset = SIMD2((view.width - image.width * s) / 2, (view.height - image.height * s) / 2)
    }

    func point(_ p: SIMD2<Double>) -> CGPoint {
        let v = p * scale + offset
        return CGPoint(x: v.x, y: v.y)
    }

    func rect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * scale + offset.x, y: r.minY * scale + offset.y, width: r.width * scale, height: r.height * scale)
    }
}
