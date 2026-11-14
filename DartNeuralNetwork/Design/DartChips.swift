import SwiftUI

/// A small segment label coloured like the bed it names (checkout routes, history).
struct SegmentChip: View {
    let segment: Segment
    var size: Size = .regular

    enum Size { case small, regular }

    var body: some View {
        let style = BedStyle(segment)
        Text(segment.label)
            .font(size == .small ? Theme.condensed(.subheadline, weight: .heavy) : Theme.condensed(.title3, weight: .heavy))
            .foregroundStyle(style.text)
            .lineLimit(1)
            .padding(.horizontal, size == .small ? 8 : 12)
            .frame(minHeight: size == .small ? 28 : 36)
            .background(style.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if style.needsOutline {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: segment == .miss ? [3, 3] : []))
                }
            }
            .accessibilityLabel(segment.spokenLabel)
    }
}

/// One of the three dart slots of a visit. Filled slots take the colour of the bed hit.
struct DartSlot: View {
    let index: Int
    let dart: Dart?
    /// The slot that the next dart goes into.
    var isNext = false
    /// Darts after a bust or finish, or slots that will not be thrown.
    var isVoid = false

    @ScaledMetric(relativeTo: .largeTitle) private var labelSize: CGFloat = 40

    var body: some View {
        ZStack {
            if let dart {
                filled(dart)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(dart == nil ? "Enter this dart" : "Correct this dart")
        .accessibilityAddTraits(.isButton)
    }

    private func filled(_ dart: Dart) -> some View {
        let style = BedStyle(dart.segment)
        return VStack(spacing: 2) {
            Text(dart.segment.label)
                .font(.system(size: min(labelSize, 56), weight: .black).width(.compressed))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("\(dart.segment.points)")
                .font(Theme.condensed(.subheadline, weight: .semibold))
                .monospacedDigit()
                .opacity(0.75)
        }
        .foregroundStyle(style.text)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if style.needsOutline {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1.5, dash: dart.segment == .miss ? [5, 4] : []))
            }
        }
        .overlay(alignment: .topTrailing) { marker(for: dart) }
        .opacity(isVoid ? 0.35 : 1)
    }

    @ViewBuilder
    private func marker(for dart: Dart) -> some View {
        if let confidence = dart.confidence, confidence < 0.6 {
            // Low-confidence detection: worth a look.
            Image(systemName: "questionmark")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Theme.bedCreamInk)
                .frame(width: 22, height: 22)
                .background(Theme.amber, in: Circle())
                .padding(8)
        } else if dart.isManual {
            Image(systemName: "hand.point.up.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(BedStyle(dart.segment).text.opacity(0.7))
                .padding(10)
        }
    }

    private var empty: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(isNext ? Theme.ink.opacity(0.55) : Theme.hairline,
                          style: StrokeStyle(lineWidth: isNext ? 2 : 1.5, dash: [6, 5]))
            .background(Theme.surface.opacity(isVoid ? 0 : 0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                Text("\(index + 1)")
                    .font(Theme.numerals(34, weight: .heavy))
                    .foregroundStyle(isNext ? Theme.inkMuted : Theme.inkFaint)
            }
            .opacity(isVoid ? 0.4 : 1)
    }

    private var accessibilityText: String {
        guard let dart else { return "Dart \(index + 1), empty" }
        return "Dart \(index + 1), \(dart.segment.spokenLabel), \(dart.segment.points) points"
    }
}

extension Segment {
    var spokenLabel: String {
        switch self {
        case .miss: return "Miss"
        case .single(let n): return "Single \(n)"
        case .double(let n): return "Double \(n)"
        case .triple(let n): return "Treble \(n)"
        case .outerBull: return "Outer bull"
        case .bull: return "Bull"
        }
    }
}
