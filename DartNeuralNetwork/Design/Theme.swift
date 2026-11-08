import SwiftUI
import UIKit

/// Design tokens. Colours come from the board itself: the red and green of the
/// doubles and trebles, the black and sisal cream of the singles.
enum Theme {
    // MARK: Colours

    static let background = dynamic(light: 0xF1F2EE, dark: 0x000000)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x17191A)
    static let surfaceRaised = dynamic(light: 0xE6E8E2, dark: 0x232627)
    static let hairline = dynamic(light: 0xD5D8D0, dark: 0x303436)
    static let ink = dynamic(light: 0x101314, dark: 0xF4F5F1)
    static let inkMuted = dynamic(light: 0x5E6560, dark: 0x9BA19C)
    static let inkFaint = dynamic(light: 0x8C938B, dark: 0x6A716D)

    static let bedRed = dynamic(light: 0xC8262E, dark: 0xE0353C)
    static let bedGreen = dynamic(light: 0x0B7F4A, dark: 0x13955A)
    static let bedBlack = dynamic(light: 0x1C1E1D, dark: 0x262928)
    static let bedCream = dynamic(light: 0xECDDB8, dark: 0xE6D5AA)
    static let bedCreamInk = Color(hex: 0x2A2416)
    static let amber = dynamic(light: 0xC77D00, dark: 0xF2A93B)

    /// Primary action colour.
    static let accent = bedGreen
    static let danger = bedRed

    // MARK: Type

    /// Scoreboard numerals: compressed, heavy, tabular.
    static func numerals(_ size: CGFloat, weight: Font.Weight = .black) -> Font {
        .system(size: size, weight: weight).width(.compressed).monospacedDigit()
    }

    /// Labels that should scale with Dynamic Type but keep the scoreboard look.
    static func condensed(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, weight: weight).width(.condensed)
    }

    // MARK: Helpers

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// The colour of the board bed a segment belongs to.
struct BedStyle {
    let fill: Color
    let text: Color
    let needsOutline: Bool

    init(_ segment: Segment) {
        switch segment {
        case .miss:
            fill = .clear; text = Theme.inkMuted; needsOutline = true
        case .bull:
            fill = Theme.bedRed; text = .white; needsOutline = false
        case .outerBull:
            fill = Theme.bedGreen; text = .white; needsOutline = false
        case .single(let n):
            if BedStyle.isDarkBed(n) {
                fill = Theme.bedBlack; text = .white; needsOutline = true
            } else {
                fill = Theme.bedCream; text = Theme.bedCreamInk; needsOutline = false
            }
        case .double(let n), .triple(let n):
            fill = BedStyle.isDarkBed(n) ? Theme.bedRed : Theme.bedGreen
            text = .white
            needsOutline = false
        }
    }

    /// 20 sits on a black single bed with red rings; the colours alternate around the board.
    static func isDarkBed(_ number: Int) -> Bool {
        (Segment.boardOrder.firstIndex(of: number) ?? 0) % 2 == 0
    }
}

// MARK: - Haptics

enum Haptics {
    static func dart() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func tap() { UISelectionFeedbackGenerator().selectionChanged() }
    static func bust() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func nextPlayer() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
}

// MARK: - Buttons

/// Large pill action. `prominent` uses the accent fill.
struct PillButtonStyle: ButtonStyle {
    var prominent = true
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(prominent ? Color.white : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 20)
            .background(prominent ? tint : Theme.surfaceRaised, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Round icon button used in top bars.
struct RoundIconButtonStyle: ButtonStyle {
    var size: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(width: size, height: size)
            .background(Theme.surfaceRaised, in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
