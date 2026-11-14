import SwiftUI

/// Game setup: starting score, double out, players.
struct HomeView: View {
    var onStart: (X01Rules, [String]) -> Void
    var onCameraCheck: () -> Void

    @AppStorage("setup.startScore") private var startScore = 501
    @AppStorage("setup.doubleOut") private var doubleOut = true
    @AppStorage("setup.players") private var storedPlayers = "[\"Player 1\"]"

    @State private var players: [EditablePlayer] = []
    @State private var customEntry = false
    @FocusState private var focusedPlayer: UUID?

    private static let presets = [301, 501, 701]
    private static let maxPlayers = 4

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    topBar
                    scorePicker
                    rules
                    playersSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.interactively)

            startButton
        }
        .onAppear(perform: loadPlayers)
        .onChange(of: players) { _, _ in savePlayers() }
        .sheet(isPresented: $customEntry) {
            CustomScoreSheet(initial: Self.presets.contains(startScore) ? 1001 : startScore) { value in
                startScore = value
            }
        }
    }

    // MARK: Sections

    private var topBar: some View {
        HStack(spacing: 10) {
            BoardView(showsNumbers: false, muted: true)
                .frame(width: 30, height: 30)
            Text("Darts")
                .font(Theme.condensed(.title2, weight: .heavy))
            Spacer()
            Button(action: onCameraCheck) {
                Image(systemName: "camera.viewfinder")
            }
            .buttonStyle(RoundIconButtonStyle())
            .accessibilityLabel("Check camera")
        }
    }

    /// The starting score is the hero: big scoreboard numerals, the chosen one in ink.
    private var scorePicker: some View {
        let isCustom = !Self.presets.contains(startScore)
        return VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                scoreRow(size: 76, isCustom: isCustom)
                scoreRow(size: 60, isCustom: isCustom)
                scoreRow(size: 46, isCustom: isCustom)
            }
        }
    }

    private func scoreRow(size: CGFloat, isCustom: Bool) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.28) {
            ForEach(Self.presets, id: \.self) { value in
                scoreOption(text: "\(value)", selected: startScore == value, size: size) {
                    startScore = value
                }
            }
            scoreOption(text: isCustom ? "\(startScore)" : "+", selected: isCustom, size: size) {
                customEntry = true
            }
            .accessibilityLabel(isCustom ? "Custom, \(startScore)" : "Custom score")
        }
    }

    private func scoreOption(text: String, selected: Bool, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            withAnimation(.snappy) { action() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(Theme.numerals(size))
                    .foregroundStyle(selected ? Theme.ink : Theme.inkFaint)
                    .fixedSize()
                Capsule()
                    .fill(selected ? Theme.accent : .clear)
                    .frame(height: 5)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var rules: some View {
        Toggle(isOn: $doubleOut.animation(.snappy)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Double out")
                    .font(.headline)
                Text(doubleOut ? "Finish on a double or the bull" : "Any dart can finish")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .tint(Theme.accent)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var playersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Players")
                .font(.headline)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(players.enumerated()), id: \.element.id) { index, player in
                    if index > 0 { Divider().padding(.leading, 60) }
                    playerRow(index: index, player: player)
                }
                if players.count < Self.maxPlayers {
                    if !players.isEmpty { Divider().padding(.leading, 60) }
                    Button(action: addPlayer) {
                        HStack(spacing: 14) {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 32, height: 32)
                                .background(Theme.surfaceRaised, in: Circle())
                            Text("Add player")
                                .font(.body.weight(.medium))
                            Spacer()
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func playerRow(index: Int, player: EditablePlayer) -> some View {
        HStack(spacing: 14) {
            Text("\(index + 1)")
                .font(Theme.numerals(17, weight: .heavy))
                .foregroundStyle(Theme.background)
                .frame(width: 32, height: 32)
                .background(Theme.ink, in: Circle())
                .accessibilityHidden(true)
            TextField("Name", text: binding(for: player.id))
                .font(.body.weight(.medium))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focusedPlayer, equals: player.id)
                .accessibilityLabel("Player \(index + 1) name")
            if players.count > 1 {
                Button {
                    withAnimation(.snappy) { players.removeAll { $0.id == player.id } }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.inkFaint)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(player.name)")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(minHeight: 56)
    }

    private var startButton: some View {
        Button {
            focusedPlayer = nil
            onStart(X01Rules(startScore: startScore, doubleOut: doubleOut), playerNames)
        } label: {
            HStack(spacing: 8) {
                Text("Start \(startScore)")
                Image(systemName: "arrow.right")
            }
        }
        .buttonStyle(PillButtonStyle())
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background(alignment: .bottom) {
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .center)
                .frame(height: 120)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: Players storage

    private var playerNames: [String] {
        players.enumerated().map { index, player in
            let trimmed = player.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Player \(index + 1)" : trimmed
        }
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { players.first { $0.id == id }?.name ?? "" },
            set: { value in
                if let index = players.firstIndex(where: { $0.id == id }) { players[index].name = value }
            }
        )
    }

    private func addPlayer() {
        let player = EditablePlayer(name: "")
        withAnimation(.snappy) { players.append(player) }
        focusedPlayer = player.id
    }

    private func loadPlayers() {
        guard players.isEmpty else { return }
        let names = (try? JSONDecoder().decode([String].self, from: Data(storedPlayers.utf8))) ?? ["Player 1"]
        players = (names.isEmpty ? ["Player 1"] : Array(names.prefix(Self.maxPlayers))).map { EditablePlayer(name: $0) }
    }

    private func savePlayers() {
        if let data = try? JSONEncoder().encode(players.map(\.name)), let json = String(data: data, encoding: .utf8) {
            storedPlayers = json
        }
    }
}

private struct EditablePlayer: Identifiable, Equatable {
    let id = UUID()
    var name: String
}

/// Number entry for a custom starting score.
private struct CustomScoreSheet: View {
    @State private var text: String
    var onSave: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(initial: Int, onSave: @escaping (Int) -> Void) {
        _text = State(initialValue: "\(initial)")
        self.onSave = onSave
    }

    private var value: Int? {
        guard let v = Int(text), (2...9999).contains(v) else { return nil }
        return v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Starting score")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(RoundIconButtonStyle(size: 36))
                    .accessibilityLabel("Close")
            }
            TextField("1001", text: $text)
                .font(Theme.numerals(88))
                .keyboardType(.numberPad)
                .focused($focused)
                .onChange(of: text) { _, new in text = String(new.filter(\.isNumber).prefix(4)) }
            Button("Use \(value.map(String.init) ?? "score")") {
                if let value { onSave(value); dismiss() }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(value == nil)
            .opacity(value == nil ? 0.5 : 1)
            Spacer()
        }
        .padding(20)
        .background(Theme.background)
        .presentationDetents([.height(320)])
        .onAppear { focused = true }
    }
}
