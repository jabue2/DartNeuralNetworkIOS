import SwiftUI

/// The live game: remaining score, the three darts of the visit, and the camera status.
struct GameView: View {
    @ObservedObject var session: GameSession
    var onExit: () -> Void
    /// DEBUG demo hooks: open the picker on a slot / expand the camera on appear.
    var initialPickerSlot: Int?
    var startsWithCameraExpanded = false

    @State private var picking: SlotSelection?
    @State private var cameraExpanded = false
    @State private var confirmLeave = false

    private var match: X01Match { session.match }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if match.isOver {
                MatchSummaryView(match: match,
                                 onRematch: { withAnimation(.snappy) { session.rematch() } },
                                 onDone: onExit)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                playing
                    .transition(.opacity)
            }

            if cameraExpanded {
                CameraFramingView(source: session.source, status: session.boardStatus) {
                    withAnimation(.snappy) { cameraExpanded = false }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                .zIndex(2)
            }
        }
        .animation(.snappy, value: match.isOver)
        // Detection needs the camera running; the summary screen may let the phone sleep.
        .keepsScreenAwake(!match.isOver)
        .sheet(item: $picking) { selection in
            SegmentPickerSheet(title: "Dart \(selection.index + 1)", current: selection.current) { segment in
                session.set(slot: selection.index, ofVisit: selection.visitNumber, to: segment)
                picking = nil
            }
        }
        .confirmationDialog("Leave this game?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave game", role: .destructive, action: onExit)
        }
        .onAppear {
            if startsWithCameraExpanded { cameraExpanded = true }
        }
        .task {
            // Demo hook: wait for the scripted darts, then open the picker on that slot.
            guard let slot = initialPickerSlot else { return }
            for _ in 0..<40 where (match.activeVisit?.darts.count ?? 0) <= slot {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            openSlot(slot)
        }
    }

    // MARK: - Playing layout

    private var playing: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 8)

            if match.players.count > 1 {
                PlayersStrip(match: match)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }

            Spacer(minLength: 8)
            hero
                .padding(.horizontal, 20)
            Spacer(minLength: 8)

            slots
                .padding(.horizontal, 20)

            bottomBar
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { confirmLeave = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(RoundIconButtonStyle())
            .accessibilityLabel("Leave game")

            HStack(spacing: 8) {
                Text("\(match.rules.startScore)")
                    .font(Theme.condensed(.title3, weight: .heavy))
                    .monospacedDigit()
                if match.rules.doubleOut {
                    Text("Double out")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.surfaceRaised, in: Capsule())
                }
            }
            .frame(height: 44)

            Spacer(minLength: 0)

            CameraTile(source: session.source, status: session.boardStatus, isHidden: cameraExpanded) {
                withAnimation(.snappy) { cameraExpanded = true }
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        let player = match.currentPlayerIndex
        let outcome = match.activeOutcome
        let shown: Int = outcome == .checkout ? (match.activeVisit?.startRemaining ?? 0) : match.remaining(for: player)
        let tint: Color = outcome == .bust ? Theme.danger : (outcome == .checkout ? Theme.accent : Theme.ink)

        return VStack(alignment: .leading, spacing: 4) {
            if match.players.count == 1 {
                Text(match.players[player])
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            HStack(alignment: .center, spacing: 12) {
                Text("\(shown)")
                    .font(Theme.numerals(200))
                    .foregroundStyle(tint)
                    .strikethrough(outcome == .bust, color: Theme.danger)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .contentTransition(.numericText(value: Double(shown)))
                    .animation(.snappy, value: shown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .accessibilityLabel(outcome == .checkout ? "Checked out \(shown)" : "\(shown) remaining")

                // Without a working camera or detector there is nothing to show on the small board.
                if session.boardStatus != .cameraUnavailable && session.boardStatus != .detectorUnavailable {
                    BoardView(markers: visitMarkers, showsNumbers: false, muted: true)
                        .frame(width: 112, height: 112)
                        .opacity(outcome == .bust ? 0.5 : 1)
                }
            }

            statusLine(outcome: outcome)
                .frame(minHeight: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where this visit's darts landed, as the camera saw them.
    private var visitMarkers: [BoardView.Marker] {
        (match.activeVisit?.darts ?? []).compactMap { dart in
            dart.boardPosition.map { BoardView.Marker(id: dart.id, position: $0) }
        }
    }

    @ViewBuilder
    private func statusLine(outcome: VisitOutcome?) -> some View {
        HStack(spacing: 8) {
            switch outcome {
            case .bust?:
                StateTag(text: "Bust", systemImage: "xmark.octagon.fill", tint: Theme.danger)
            case .checkout?:
                StateTag(text: "Checkout", systemImage: "trophy.fill", tint: Theme.accent)
            default:
                if let route = match.checkoutSuggestion {
                    HStack(spacing: 8) {
                        Image(systemName: "flag.checkered")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.inkMuted)
                        ForEach(Array(route.enumerated()), id: \.offset) { _, segment in
                            SegmentChip(segment: segment)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Checkout: " + route.map(\.spokenLabel).joined(separator: ", "))
                }
            }
            Spacer(minLength: 0)
            if let visit = match.activeVisit, !visit.darts.isEmpty, outcome != .bust {
                Text("+\(X01.evaluate(visit, rules: match.rules).scored)")
                    .font(Theme.condensed(.title2, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
                    .accessibilityLabel("Visit total \(X01.evaluate(visit, rules: match.rules).scored)")
            }
        }
    }

    // MARK: Slots

    private var slots: some View {
        let visit = match.activeVisit
        let darts = visit?.darts ?? []
        let outcome = match.activeOutcome ?? .open

        return HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                let dart = index < darts.count ? darts[index] : nil
                let isVoid = dart == nil && outcome != .open
                Button {
                    openSlot(index)
                } label: {
                    DartSlot(index: index,
                             dart: dart,
                             isNext: outcome == .open && index == darts.count,
                             isVoid: isVoid)
                }
                .buttonStyle(SlotButtonStyle())
                .disabled(isVoid)
            }
        }
        .animation(.snappy, value: darts)
    }

    private func openSlot(_ index: Int) {
        let darts = match.activeVisit?.darts ?? []
        if index < darts.count {
            picking = SlotSelection(index: index, visitNumber: session.currentVisitNumber, current: darts[index].segment)
        } else if (match.activeOutcome ?? .open) == .open {
            picking = SlotSelection(index: darts.count, visitNumber: session.currentVisitNumber, current: nil)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        let outcome = match.activeOutcome
        let visitDone = outcome != nil && outcome != .open
        let nextIndex = (match.currentPlayerIndex + 1) % match.players.count

        return VStack(spacing: 10) {
            if visitDone && outcome != .checkout && session.boardStatus.isScoring {
                Label("Pull your darts to continue", systemImage: "hand.raised.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.inkMuted)
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                Button { session.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(RoundIconButtonStyle(size: 56))
                .disabled(!match.canUndo)
                .opacity(match.canUndo ? 1 : 0.4)
                .accessibilityLabel("Undo")

                Button { session.next() } label: {
                    HStack(spacing: 8) {
                        if outcome == .checkout {
                            Text("Finish leg")
                        } else if match.players.count > 1 {
                            Text("Next")
                            Text(match.players[nextIndex])
                                .opacity(0.7)
                                .lineLimit(1)
                        } else {
                            Text("Next visit")
                        }
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: visitDone))
            }
        }
        .animation(.snappy, value: visitDone)
    }
}

private struct SlotSelection: Identifiable {
    let index: Int
    /// `GameSession.currentVisitNumber` when the picker opened.
    let visitNumber: Int
    let current: Segment?
    var id: Int { index }
}

private struct SlotButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A short coloured state label ("Bust", "Checkout").
struct StateTag: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(Theme.condensed(.title3, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Remaining score of every player; the player at the oche is inverted.
private struct PlayersStrip: View {
    let match: X01Match

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(match.players.enumerated()), id: \.offset) { index, name in
                let active = index == match.currentPlayerIndex
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .opacity(active ? 0.8 : 0.65)
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(match.remainingBeforeActiveVisit(for: index))")
                            .font(Theme.numerals(30, weight: .heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Spacer(minLength: 4)
                        let stats = match.stats(for: index)
                        if stats.dartsThrown > 0 {
                            Text("avg " + String(format: "%.1f", stats.threeDartAverage))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .opacity(0.6)
                        }
                    }
                }
                .foregroundStyle(active ? Theme.background : Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? Theme.ink : Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name), \(match.remainingBeforeActiveVisit(for: index)) remaining" + (active ? ", throwing" : ""))
            }
        }
        .animation(.snappy, value: match.currentPlayerIndex)
    }
}
