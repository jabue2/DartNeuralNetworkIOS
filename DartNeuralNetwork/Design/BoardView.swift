import SwiftUI

/// A vector dartboard with optional dart markers.
struct BoardView: View {
    struct Marker: Identifiable, Hashable {
        let id: UUID
        var position: BoardPoint
        var highlighted: Bool = true
    }

    var markers: [Marker] = []
    var showsNumbers = true
    /// Flat style for small sizes and heatmaps; full style for the demo camera scene.
    var muted = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = side / 2
            let unit = outer / BoardGeometry.numberRing   // points per BoardPoint unit

            drawBoard(in: &context, center: center, outer: outer, unit: unit)
            if showsNumbers { drawNumbers(in: &context, center: center, unit: unit) }
            drawMarkers(in: &context, center: center, unit: unit)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var black: Color { muted ? Color(hex: 0x2B2E2C) : Color(hex: 0x1A1B1A) }
    private var cream: Color { muted ? Color(hex: 0xD9CCA8) : Color(hex: 0xEADBB4) }
    private var red: Color { Color(hex: 0xC8262E) }
    private var green: Color { Color(hex: 0x0B7F4A) }

    private func drawBoard(in context: inout GraphicsContext, center: CGPoint, outer: CGFloat, unit: CGFloat) {
        context.fill(Path(ellipseIn: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2)),
                     with: .color(Color(hex: 0x111211)))

        func wedge(_ inner: Double, _ outerR: Double, startDeg: Double, endDeg: Double) -> Path {
            var path = Path()
            // Angles clockwise from top → SwiftUI angles from +x.
            let a0 = Angle.degrees(startDeg - 90), a1 = Angle.degrees(endDeg - 90)
            path.addArc(center: center, radius: outerR * unit, startAngle: a0, endAngle: a1, clockwise: false)
            path.addArc(center: center, radius: inner * unit, startAngle: a1, endAngle: a0, clockwise: true)
            path.closeSubpath()
            return path
        }

        for (index, number) in Segment.boardOrder.enumerated() {
            let mid = Double(index) * 18
            let start = mid - 9, end = mid + 9
            let dark = BedStyle.isDarkBed(number)
            let single = dark ? black : cream
            let ring = dark ? red : green
            context.fill(wedge(BoardGeometry.outerBullRadius, BoardGeometry.trebleInner, startDeg: start, endDeg: end), with: .color(single))
            context.fill(wedge(BoardGeometry.trebleInner, BoardGeometry.trebleOuter, startDeg: start, endDeg: end), with: .color(ring))
            context.fill(wedge(BoardGeometry.trebleOuter, BoardGeometry.doubleInner, startDeg: start, endDeg: end), with: .color(single))
            context.fill(wedge(BoardGeometry.doubleInner, BoardGeometry.doubleOuter, startDeg: start, endDeg: end), with: .color(ring))
        }

        let outerBull = BoardGeometry.outerBullRadius * unit
        context.fill(Path(ellipseIn: CGRect(x: center.x - outerBull, y: center.y - outerBull, width: outerBull * 2, height: outerBull * 2)), with: .color(green))
        let bull = BoardGeometry.bullRadius * unit
        context.fill(Path(ellipseIn: CGRect(x: center.x - bull, y: center.y - bull, width: bull * 2, height: bull * 2)), with: .color(red))

        // Wires
        if !muted && unit > 40 {
            let wire = GraphicsContext.Shading.color(Color(hex: 0xB8BCB9).opacity(0.55))
            for r in [BoardGeometry.outerBullRadius, BoardGeometry.trebleInner, BoardGeometry.trebleOuter, BoardGeometry.doubleInner, BoardGeometry.doubleOuter] {
                let radius = r * unit
                context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: wire, lineWidth: 0.6)
            }
            for index in 0..<20 {
                let radians = (Double(index) * 18 - 9) * .pi / 180
                var path = Path()
                path.move(to: CGPoint(x: center.x + sin(radians) * BoardGeometry.outerBullRadius * unit, y: center.y - cos(radians) * BoardGeometry.outerBullRadius * unit))
                path.addLine(to: CGPoint(x: center.x + sin(radians) * unit, y: center.y - cos(radians) * unit))
                context.stroke(path, with: wire, lineWidth: 0.6)
            }
        }
    }

    private func drawNumbers(in context: inout GraphicsContext, center: CGPoint, unit: CGFloat) {
        let radius = (BoardGeometry.doubleOuter + BoardGeometry.numberRing) / 2 * unit
        let fontSize = max(7, unit * 0.1)
        for number in Segment.boardOrder {
            let radians = BoardGeometry.angle(of: number) * .pi / 180
            let point = CGPoint(x: center.x + sin(radians) * radius, y: center.y - cos(radians) * radius)
            let text = Text("\(number)").font(.system(size: fontSize, weight: .bold).width(.condensed)).foregroundColor(Color(hex: 0xE9EAE6))
            context.draw(text, at: point)
        }
    }

    private func drawMarkers(in context: inout GraphicsContext, center: CGPoint, unit: CGFloat) {
        let size = max(6, unit * 0.075)
        for marker in markers {
            let point = CGPoint(x: center.x + marker.position.x * unit, y: center.y + marker.position.y * unit)
            let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            if marker.highlighted {
                context.fill(Path(ellipseIn: rect.insetBy(dx: -size * 0.35, dy: -size * 0.35)), with: .color(.white))
                context.fill(Path(ellipseIn: rect), with: .color(Color(hex: 0x0E7AFE)))
            } else {
                context.fill(Path(ellipseIn: rect.insetBy(dx: size * 0.15, dy: size * 0.15)), with: .color(.white.opacity(0.85)))
            }
        }
    }
}

#Preview {
    BoardView(markers: [
        .init(id: UUID(), position: BoardGeometry.point(in: .triple(20))!),
        .init(id: UUID(), position: BoardGeometry.point(in: .double(16))!),
    ])
    .padding()
}
