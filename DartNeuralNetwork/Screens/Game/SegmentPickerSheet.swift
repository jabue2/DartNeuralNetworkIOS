import SwiftUI

/// Fast dart entry: pick single, double or treble, then tap the number.
struct SegmentPickerSheet: View {
    let title: String
    let current: Segment?
    var onPick: (Segment) -> Void

    @State private var ring: Ring
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    enum Ring: Int, CaseIterable, Identifiable {
        case single = 1, double, treble
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .single: return "Single"
            case .double: return "Double"
            case .treble: return "Treble"
            }
        }
        func segment(_ n: Int) -> Segment {
            switch self {
            case .single: return .single(n)
            case .double: return .double(n)
            case .treble: return .triple(n)
            }
        }
    }

    init(title: String, current: Segment?, onPick: @escaping (Segment) -> Void) {
        self.title = title
        self.current = current
        self.onPick = onPick
        let ring: Ring
        switch current {
        case .double?: ring = .double
        case .triple?: ring = .treble
        default: ring = .single
        }
        _ring = State(initialValue: ring)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ringPicker
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(1...20, id: \.self) { n in
                    numberKey(n)
                }
            }
            HStack(spacing: 8) {
                specialKey(.outerBull, title: "25")
                specialKey(.bull, title: "Bull")
                specialKey(.miss, title: "Miss")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(480), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(Theme.condensed(.title, weight: .heavy))
            if let current {
                SegmentChip(segment: current)
                    .accessibilityLabel("Currently \(current.spokenLabel)")
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(RoundIconButtonStyle(size: 36))
                .accessibilityLabel("Close")
        }
    }

    private var ringPicker: some View {
        HStack(spacing: 4) {
            ForEach(Ring.allCases) { option in
                let selected = option == ring
                Button {
                    ring = option
                    Haptics.tap()
                } label: {
                    Text(option.title)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selected ? Theme.background : Theme.ink)
                        .background(selected ? Theme.ink : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func numberKey(_ n: Int) -> some View {
        let segment = ring.segment(n)
        let style = BedStyle(segment)
        let isCurrent = segment == current
        return Button {
            onPick(segment)
        } label: {
            Text("\(n)")
                .font(Theme.numerals(28, weight: .heavy))
                .foregroundStyle(style.text)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(style.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isCurrent ? Theme.ink : (style.needsOutline ? Theme.hairline : .clear),
                                      lineWidth: isCurrent ? 3 : 1)
                }
        }
        .buttonStyle(KeyButtonStyle())
        .accessibilityLabel(segment.spokenLabel)
    }

    private func specialKey(_ segment: Segment, title: String) -> some View {
        let style = BedStyle(segment)
        let isCurrent = segment == current
        return Button {
            onPick(segment)
        } label: {
            Text(title)
                .font(Theme.condensed(.title3, weight: .heavy))
                .foregroundStyle(segment == .miss ? Theme.ink : style.text)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(segment == .miss ? Theme.surfaceRaised : style.fill,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.ink, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(KeyButtonStyle())
        .accessibilityLabel(segment.spokenLabel)
    }
}

private struct KeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
