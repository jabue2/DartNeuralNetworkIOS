import SwiftUI

/// End of the leg: winner, where the darts landed, and the numbers.
struct MatchSummaryView: View {
    let match: X01Match
    var onRematch: () -> Void
    var onDone: () -> Void
    /// "Report a mistake" (a wrong dart can end the leg); nil hides the button.
    var onReport: (() -> Void)? = nil

    var body: some View {
        let winner = match.winnerIndex ?? 0
        let winnerStats = match.stats(for: winner)

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Spacer()
                        if let onReport {
                            ReportMistakeButton(action: onReport)
                        }
                        Button(action: onDone) { Image(systemName: "xmark") }
                            .buttonStyle(RoundIconButtonStyle())
                            .accessibilityLabel("Close")
                    }

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Leg won", systemImage: "trophy.fill")
                                .font(.headline)
                                .foregroundStyle(Theme.accent)
                            Text(match.players[winner])
                                .font(.system(size: 64, weight: .black).width(.compressed))
                                .lineLimit(2)
                                .minimumScaleFactor(0.5)
                            if let checkout = winnerStats.checkout {
                                Text("Out on \(checkout) in \(winnerStats.dartsThrown) darts")
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(Theme.inkMuted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                        heatmap
                    }

                    statsTable
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            HStack(spacing: 12) {
                Button("Done", action: onDone)
                    .buttonStyle(PillButtonStyle(prominent: false))
                Button(action: onRematch) {
                    Label("Rematch", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    /// All darts the camera placed on the board; the winner's are highlighted.
    @ViewBuilder
    private var heatmap: some View {
        let winner = match.winnerIndex ?? 0
        let markers: [BoardView.Marker] = match.visits.flatMap { visit in
            visit.darts.compactMap { dart in
                dart.boardPosition.map { BoardView.Marker(id: dart.id, position: $0, highlighted: visit.playerIndex == winner) }
            }
        }
        if !markers.isEmpty {
            BoardView(markers: markers, showsNumbers: false, muted: true)
                .frame(width: 128, height: 128)
        }
    }

    private var statsTable: some View {
        let rows: [(String, (PlayerStats) -> String)] = [
            ("3-dart average", { String(format: "%.1f", $0.threeDartAverage) }),
            ("Darts", { "\($0.dartsThrown)" }),
            ("Best visit", { "\($0.bestVisit)" }),
            ("Checkout", { $0.checkout.map(String.init) ?? "–" }),
            ("Darts at double", { "\($0.dartsAtDouble)" }),
        ]
        let stats = match.players.indices.map { match.stats(for: $0) }
        let winner = match.winnerIndex

        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            if match.players.count > 1 {
                GridRow {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .gridCellUnsizedAxes(.vertical)
                    ForEach(match.players.indices, id: \.self) { index in
                        Text(match.players[index])
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(index == winner ? Theme.ink : Theme.inkMuted)
                            .lineLimit(1)
                            .gridColumnAlignment(.trailing)
                    }
                }
                .padding(.bottom, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(row.0)
                        .font(.body)
                        .foregroundStyle(Theme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(match.players.indices, id: \.self) { index in
                        Text(row.1(stats[index]))
                            .font(Theme.condensed(.title2, weight: index == winner ? .heavy : .semibold))
                            .monospacedDigit()
                            .foregroundStyle(index == winner ? Theme.ink : Theme.inkMuted)
                            .gridColumnAlignment(.trailing)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }
}
