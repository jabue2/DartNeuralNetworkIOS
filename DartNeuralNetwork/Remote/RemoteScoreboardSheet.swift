import CoreImage.CIFilterBuiltins
import SwiftUI

/// "Show on another screen": turns the web scoreboard on and shows its address and QR code.
struct RemoteScoreboardSheet: View {
    @ObservedObject var remote: RemoteScoreboard
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Text("Open the scoreboard in a browser on a laptop, tablet or TV on the same Wi‑Fi. It updates live, and you can correct darts there.")
                    .font(.body)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: Binding(get: { remote.isOn }, set: { $0 ? remote.turnOn() : remote.turnOff() })) {
                    Text("Share scoreboard").font(.headline)
                }
                .tint(Theme.accent)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if remote.isOn { details }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .onAppear { remote.refreshAddress() }
    }

    private var header: some View {
        HStack {
            Text("Show on another screen")
                .font(Theme.condensed(.title, weight: .heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(RoundIconButtonStyle(size: 36))
                .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private var details: some View {
        if case .failed(let message) = remote.state {
            notice("Could not start the scoreboard: \(message)", systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
        } else if remote.address == nil {
            notice("Connect the phone to Wi‑Fi (or turn on its Personal Hotspot) so other screens can reach it.",
                   systemImage: "wifi.slash", tint: Theme.amber)
        } else if let url = remote.url {
            VStack(spacing: 16) {
                QRCodeView(text: url.absoluteString)
                    .frame(width: 220, height: 220)
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityLabel("QR code for the scoreboard address")

                Button {
                    UIPasteboard.general.string = url.absoluteString
                    copied = true
                    Haptics.tap()
                } label: {
                    VStack(spacing: 4) {
                        Text(url.absoluteString.replacingOccurrences(of: "http://", with: ""))
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Label(copied ? "Copied" : "Tap to copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .padding(.horizontal, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Copies the address")

                viewersLine
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                Text("Anyone on this Wi‑Fi who has the address can change the score. A new link locks out screens opened with the old one.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    remote.newLink()
                    copied = false
                } label: {
                    Label("New link", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .tint(Theme.ink)
                if remote.viewers == 0 {
                    Text("Page doesn’t load? Allow Local Network for Darts in Settings › Privacy & Security.")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Starting…").foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private var viewersLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(remote.viewers > 0 ? Theme.accent : Theme.inkFaint)
                .frame(width: 8, height: 8)
            Text(remote.viewers == 0 ? "No screen connected yet"
                 : remote.viewers == 1 ? "1 screen connected" : "\(remote.viewers) screens connected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(remote.viewers > 0 ? Theme.ink : Theme.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }

    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A crisp QR code (black on white, so phone cameras read it in dark mode too).
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.white
        }
    }

    private static let context = CIContext()

    static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
