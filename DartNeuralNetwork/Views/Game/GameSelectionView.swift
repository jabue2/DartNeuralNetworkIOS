import SwiftUI

struct GameSelectionView: View {
    @State private var showCustom = false
    @State private var customScore: Int = 701
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Title
                    Text("Choose your game")
                        .font(.largeTitle.bold())
                        .padding(.top, 8)
                        .padding(.horizontal)

                    // Cards
                    VStack(spacing: 14) {
                        GameCardButton(
                            title: "301",
                            subtitle: "Classic short leg",
                            tags: ["3 darts / turn", "Exact checkout"],
                            symbol: "target",
                            gradient: LinearGradient(colors: [.blue.opacity(0.9), .blue.opacity(0.5)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                        ) {
                            path.append(StartScoreRoute.score(301))
                        }

                        GameCardButton(
                            title: "501",
                            subtitle: "Standard match play",
                            tags: ["3 darts / turn", "Exact checkout"],
                            symbol: "trophy",
                            gradient: LinearGradient(colors: [.green.opacity(0.9), .green.opacity(0.5)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                        ) {
                            path.append(StartScoreRoute.score(501))
                        }

                        GameCardButton(
                            title: "Custom",
                            subtitle: "Pick your starting score",
                            tags: ["301–1001"],
                            symbol: "slider.horizontal.3",
                            gradient: LinearGradient(colors: [.purple.opacity(0.9), .purple.opacity(0.5)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                        ) {
                            showCustom = true
                        }
                    }
                    .padding(.horizontal)

                    // Quick rules
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick rules")
                            .font(.headline)
                        RuleTag(text: "3 darts per turn")
                        RuleTag(text: "Score must reach exactly 0")
                        RuleTag(text: "Bust resets the turn’s score")
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("Darts")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCustom) {
                CustomScoreSheet(customScore: $customScore) {
                    path.append(StartScoreRoute.score(clampedCustom))
                }
            }
            .navigationDestination(for: StartScoreRoute.self) { route in
                switch route {
                case .score(let s):
                    DartsGameLiveView(startingScore: s)
                }
            }
        }
    }

    private var clampedCustom: Int {
        min(1001, max(301, customScore))
    }
}

// MARK: - Route

private enum StartScoreRoute: Hashable {
    case score(Int)
}

// MARK: - Components

private struct GameCardButton: View {
    let title: String
    let subtitle: String
    let tags: [String]
    let symbol: String
    let gradient: LinearGradient
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.thinMaterial)
                        .frame(width: 56, height: 56)
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title2.bold())
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Tags
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(gradient)
            )
            .foregroundStyle(.white)
            .shadow(radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle).")
    }
}

private struct RuleTag: View {
    let text: String
    var body: some View {
        HStack {
            Image(systemName: "info.circle")
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

private struct CustomScoreSheet: View {
    @Binding var customScore: Int
    var onStart: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Starting score") {
                    Stepper(value: $customScore, in: 301...1001, step: 50) {
                        Text("\(customScore)")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Direct input")
                        Spacer()
                        TextField("e.g. 701", value: $customScore, formatter: NumberFormatter())
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                }

                Section {
                    Button {
                        onStart()
                        dismiss()
                    } label: {
                        Label("Start game", systemImage: "play.fill")
                    }
                }
            }
            .navigationTitle("Custom game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

