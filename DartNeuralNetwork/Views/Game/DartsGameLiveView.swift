import SwiftUI
import AVFoundation

// MARK: - Vector overlay
struct DartOverlayView: View {
    let overlay: DetectionOverlay
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(overlay.dartBoxes.enumerated()), id: \.offset) { _, box in
                    Rectangle()
                        .stroke(lineWidth: 2)
                        .frame(width: box.width * geo.size.width,
                               height: box.height * geo.size.height)
                        .position(x: box.midX * geo.size.width,
                                  y: (1 - box.midY) * geo.size.height)
                        .opacity(0.9)
                }
                ForEach(Array(overlay.dartCenters.enumerated()), id: \.offset) { _, p in
                    Circle()
                        .frame(width: 10, height: 10)
                        .position(x: p.x * geo.size.width,
                                  y: (1 - p.y) * geo.size.height)
                }
            }
        }
    }
}

private struct RemoveDartsBanner: View {
    var body: some View {
        Text("Remove darts to continue…")
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 3)
            .padding(.top, 10)
            .accessibilityLabel("Remove darts to continue")
    }
}

struct EditLastTurnSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var darts: [EditableDart]
    var onSave: ([DartHit]) -> Void

    init(initialHits: [DartHit], onSave: @escaping ([DartHit]) -> Void) {
        self.onSave = onSave
        let mapped = initialHits.map { EditableDart(from: $0) }
        let padded = mapped + Array(repeating: EditableDart(), count: max(0, 3 - mapped.count))
        _darts = State(initialValue: Array(padded.prefix(3)))
    }

    var body: some View {
        NavigationView {
            Form {
                ForEach(0..<3, id: \.self) { i in
                    Section("Dart \(i + 1)") {
                        Picker("Type", selection: $darts[i].kind) {
                            Text("Miss").tag(EditableDart.Kind.miss)
                            Text("Single").tag(EditableDart.Kind.single)
                            Text("Double").tag(EditableDart.Kind.double)
                            Text("Triple").tag(EditableDart.Kind.triple)
                            Text("Outer Bull (25)").tag(EditableDart.Kind.outerBull)
                            Text("Bull (50)").tag(EditableDart.Kind.bull)
                        }
                        .pickerStyle(.menu)

                        if darts[i].kind.isNumbered {
                            Stepper(value: $darts[i].value, in: 1...20) {
                                Text("Number: \(darts[i].value)")
                            }
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Edited total")
                        Spacer()
                        Text("\(editedTotal)").bold().monospacedDigit()
                    }
                }
            }
            .navigationTitle("Edit last turn")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let hits: [DartHit] = darts.map { $0.toHit() }
                        onSave(hits)
                        dismiss()
                    }
                }
            }
        }
    }

    private var editedTotal: Int {
        darts.map { $0.points }.reduce(0, +)
    }
}


private struct EditableDart {
    enum Kind: String, CaseIterable, Identifiable {
        case single, double, triple, outerBull, bull, miss
        var id: String { rawValue }
        var isNumbered: Bool { self == .single || self == .double || self == .triple }
    }
    var kind: Kind = .miss
    var value: Int = 20  // default for S/D/T

    var points: Int {
        switch kind {
        case .single: return value
        case .double: return 2 * value
        case .triple: return 3 * value
        case .outerBull: return 25
        case .bull: return 50
        case .miss: return 0
        }
    }

    func toHit() -> DartHit {
        switch kind {
        case .single:     return DartHit(center: .zero, label: "S\(value)", points: value)
        case .double:     return DartHit(center: .zero, label: "D\(value)", points: 2 * value)
        case .triple:     return DartHit(center: .zero, label: "T\(value)", points: 3 * value)
        case .outerBull:  return DartHit(center: .zero, label: "Outer Bull", points: 25)
        case .bull:       return DartHit(center: .zero, label: "Bull", points: 50)
        case .miss:       return DartHit(center: .zero, label: "0", points: 0)
        }
    }
}

extension EditableDart {
    init(from hit: DartHit) {
        let raw = hit.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = raw.lowercased()

        // Match "S20", "D 16", "t7", etc. (case-insensitive, optional space)
        if let m = try? NSRegularExpression(pattern: #"^\s*([sdt])\s*(\d{1,2})\s*$"#, options: .caseInsensitive)
            .firstMatch(in: raw, options: [], range: NSRange(location: 0, length: raw.utf16.count)),
           let kindRange = Range(m.range(at: 1), in: raw),
           let numRange  = Range(m.range(at: 2), in: raw),
           let v = Int(raw[numRange]) {

            let clamped = max(1, min(20, v))
            switch raw[kindRange].lowercased() {
            case "s": self.kind = .single
            case "d": self.kind = .double
            case "t": self.kind = .triple
            default:  self.kind = .miss
            }
            self.value = clamped
            return
        }

        // Bulls
        if l.contains("outer") || l == "25" || hit.points == 25 {
            self.kind = .outerBull
            self.value = 20
            return
        }
        if l == "bull" || l.contains("inner bull") || l == "50" || hit.points == 50 {
            self.kind = .bull
            self.value = 20
            return
        }

        // Miss / zero
        if l == "0" || l == "miss" || hit.points == 0 {
            self.kind = .miss
            self.value = 20
            return
        }

        // Fallback: best-effort by points (rarely needed if labels are consistent)
        switch hit.points {
        case 25: self.kind = .outerBull; self.value = 20
        case 50: self.kind = .bull;      self.value = 20
        default:
            // Try to infer numbered singles/doubles/triples by divisibility
            if (1...20).contains(hit.points) {
                self.kind = .single; self.value = hit.points
            } else if hit.points % 2 == 0, (1...20).contains(hit.points / 2) {
                self.kind = .double; self.value = hit.points / 2
            } else if hit.points % 3 == 0, (1...20).contains(hit.points / 3) {
                self.kind = .triple; self.value = hit.points / 3
            } else {
                self.kind = .miss; self.value = 20
            }
        }
    }
}



// MARK: - Live game view (no scrolling)
struct DartsGameLiveView: View {
    @StateObject private var controller = LiveDartDetectionController()

    @State private var scoreHUD: String = ""
    @State private var showHUD: Bool = false
    @State private var showEdit = false

    @State private var showResetConfirm = false
    @State private var annotateEnabled = false
    @State private var torchEnabled = false
    @State private var showHelp = false

    var startingScore: Int = 301
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        NavigationView {
            ZStack {
                GeometryReader { geo in
                    // Proportions: tweak as you like
                    let isCompact = (vSize == .compact) // e.g., landscape
                    let headerH  = min(120, geo.size.height * (isCompact ? 0.18 : 0.20))
                    let liveH    = max(200, geo.size.height * (isCompact ? 0.62 : 0.60))
                    let historyH = max(80,  geo.size.height - headerH - liveH - 24) // 24 = vertical paddings

                    VStack(spacing: 8) {
                        // Scoreboard (fixed height)
                        ScoreboardView(
                            remaining: controller.gameScore,
                            lastRound: controller.lastScoreText,
                            dartsThrown: controller.dartsThisLeg
                        )
                        .frame(height: headerH)
                        .padding(.horizontal)

                        // Live camera + overlay (dominant)
                        LiveDetectionContainer(
                            controller: controller,
                            annotateEnabled: annotateEnabled
                        )
                        .frame(height: liveH)
                        .cornerRadius(12)
                        .shadow(radius: 5)
                        .padding(.horizontal)

                        // Throw history (fixed height, last 3 only)
                        ThrowHistoryCompact(
                            history: Array(controller.throwHistory.suffix(3)),
                            title: "History (last 3)"
                        )
                        .frame(height: historyH)
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 12)
                }
            }
            .overlay(
                VStack(spacing: 8) {
                    if showHUD {
                        HUDText(text: scoreHUD)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if controller.isWaitingForRemoval {
                        RemoveDartsBanner()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
                , alignment: .top
            )
            .navigationBarTitle("Darts Live", displayMode: .inline)
            .toolbar {
                // LEFT: clearer annotations toggle
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        withAnimation { annotateEnabled.toggle() }
                    } label: {
                        Label(annotateEnabled ? "Annotations: On" : "Annotations: Off",
                              systemImage: annotateEnabled ? "viewfinder.circle.fill" : "viewfinder.circle")
                    }
                    .accessibilityLabel(annotateEnabled ? "Annotations on" : "Annotations off")
                }

                // RIGHT: torch, reset, help
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        torchEnabled.toggle()
                        controller.setTorch(enabled: torchEnabled)
                    } label: {
                        Label("Torch", systemImage: torchEnabled ? "flashlight.on.fill" : "flashlight.off.fill")
                    }

                    Button(role: .destructive) { showResetConfirm = true } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    
                    Button {
                        showEdit = true
                    } label: {
                        Label("Edit Last", systemImage: "pencil")
                    }
                    .disabled(controller.getLastFinalizedTurn().isEmpty)
                    .sheet(isPresented: $showEdit) {
                        EditLastTurnSheet(
                            initialHits: controller.getLastFinalizedTurn()
                        ) { editedHits in
                            controller.applyEditedLastTurn(editedHits)
                        }
                        .onAppear { controller.pauseSession() }
                    }


                    Button { showHelp = true } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                }
            }
            .confirmationDialog("Reset game?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Reset to \(startingScore)", role: .destructive) {
                    resetGame(to: startingScore)
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showHelp) { HelpSheet() }
            .task { await configureAndStart() }
            .onDisappear { controller.stopSession() }
            .onReceive(controller.$lastScoreText) { text in
                guard !text.isEmpty else { return }
                scoreHUD = text
                withAnimation { showHUD = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation { showHUD = false }
                }
            }
        }
    }

    // MARK: - Helpers

    private func configureAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted { startSession() }
        default:
            break
        }
    }

    private func startSession() {
        controller.gameMode = startingScore
        controller.gameScore = startingScore
        controller.lastScoreText = "Game started. Score: \(startingScore)"
        controller.restartSession()
        controller.onDetectionUpdate = { _, _ in }
    }

    private func resetGame(to score: Int) {
        controller.resetGame(to: score)
    }
}

// MARK: - Subviews (unchanged except ThrowHistoryCompact)

private struct ScoreboardView: View {
    let remaining: Int
    let lastRound: String
    let dartsThrown: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Remaining")
                    .font(.headline)
                    .minimumScaleFactor(0.8)
                Spacer()
                Text("\(remaining)")
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: remaining)
                    .accessibilityLabel("Remaining \(remaining)")
            }
            .padding(10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Label("Last", systemImage: "target")
                Spacer()
                Text(lastRound.isEmpty ? "—" : lastRound)
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(10)
            .background(Color(UIColor.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Label("Darts thrown", systemImage: "chart.bar")
                Spacer()
                Text("\(dartsThrown)").monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

private struct LiveDetectionContainer: View {
    @ObservedObject var controller: LiveDartDetectionController
    var annotateEnabled: Bool

    var body: some View {
        ZStack {
            LiveDetectionView(controller: controller, scoreText: .constant(""))

            // Pause / Resume
            VStack {
                HStack {
                    Spacer()
                    Button {
                        controller.isPaused.toggle()
                        controller.isPaused ? controller.pauseSession() : controller.resumeSession()
                    } label: {
                        Image(systemName: controller.isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.system(size: 28))
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(controller.isPaused ? "Resume detection" : "Pause detection")
                }
                .padding(12)
                Spacer()
            }

            if annotateEnabled {
                DartOverlayView(overlay: controller.overlay)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// Compact, non-scrolling history (last 3 only)
private struct ThrowHistoryCompact: View {
    let history: [String]
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if history.isEmpty {
                Text("No throws yet")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                ForEach(Array(history.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.grid.3x3")
                        Text(line)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer()
                    }
                    .font(.footnote)
                    .padding(8)
                    .background(Color(UIColor.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}

private struct HUDText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.headline)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(radius: 3)
            .padding(.top, 10)
    }
}

// HelpSheet from the previous message can remain unchanged
private struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Controls")) {
                    Label { VStack(alignment: .leading) {
                        Text("Annotations").font(.headline)
                        Text("Toggle the dart overlay (boxes and points) on the live camera.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }} icon: { Image(systemName: "viewfinder.circle") }

                    Label { VStack(alignment: .leading) {
                        Text("Torch").font(.headline)
                        Text("Turn the flashlight on or off to improve lighting.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }} icon: { Image(systemName: "flashlight.on.fill") }

                    Label { VStack(alignment: .leading) {
                        Text("Pause / Resume").font(.headline)
                        Text("Pause or resume the live detection. Pausing stops processing frames.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }} icon: { Image(systemName: "pause.circle.fill") }

                    Label { VStack(alignment: .leading) {
                        Text("Reset").font(.headline)
                        Text("Reset the game back to the starting score and clear history.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }} icon: { Image(systemName: "arrow.counterclockwise") }
                }
                Section(header: Text("Editing the last turn")) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("When to edit")
                                .font(.headline)
                            Text("If a dart was misread or missed, fix the last completed turn.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "pencil") }

                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("How to edit")
                                .font(.headline)
                            Text("""
                1. Tap **Edit Last** (pencil) in the top-right.
                2. Choose each dart: Miss, Single/Double/Triple with number, Outer Bull (25), or Bull (50).
                3. Tap **Save**. The app replays that turn from its original start score, including bust logic.
                """)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "list.number") }

                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notes")
                                .font(.headline)
                            Text("Edits affect only the most recent completed turn. You can edit again if needed.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "info.circle") }
                }
            }
            .navigationTitle("Help")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Done") { dismiss() } } }
        }
    }
}
