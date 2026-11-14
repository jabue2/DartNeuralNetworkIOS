import SwiftUI
import UIKit

/// Keeps the display on while a screen that watches the board is open. Without it iOS dims and
/// locks the phone after the auto-lock delay when nobody touches it, and a locked phone stops the
/// camera, so detection would stop in the middle of a game.
///
/// Several views can ask at once (for example during a transition between two screens), so the
/// requests are counted and the display may sleep again only when the last one is gone.
@MainActor
enum ScreenAwake {
    private(set) static var requests = 0
    /// Applies the setting. Tests replace it to observe the calls.
    static var apply: (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }

    static func acquire() {
        requests += 1
        if requests == 1 { apply(true) }
    }

    static func release() {
        guard requests > 0 else { return }
        requests -= 1
        if requests == 0 { apply(false) }
    }
}

private struct KeepsScreenAwake: ViewModifier {
    var isActive: Bool
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear { hold(isActive) }
            .onDisappear { hold(false) }
            .onChange(of: isActive) { _, active in hold(active) }
    }

    private func hold(_ wanted: Bool) {
        guard wanted != holding else { return }
        holding = wanted
        if wanted { ScreenAwake.acquire() } else { ScreenAwake.release() }
    }
}

extension View {
    /// Keeps the display on while this view is shown and `isActive` is true.
    func keepsScreenAwake(_ isActive: Bool = true) -> some View {
        modifier(KeepsScreenAwake(isActive: isActive))
    }
}
