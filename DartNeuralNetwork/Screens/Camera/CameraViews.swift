import SwiftUI
import UIKit

extension BoardStatus {
    var title: String {
        switch self {
        case .cameraUnavailable: return "No camera"
        case .detectorUnavailable: return "Scoring unavailable"
        case .searching: return "Find the board"
        case .aligning: return "Hold steady"
        case .ready: return "Board locked"
        }
    }

    var symbol: String {
        switch self {
        case .cameraUnavailable: return "video.slash.fill"
        case .detectorUnavailable: return "exclamationmark.triangle.fill"
        case .searching: return "viewfinder"
        case .aligning: return "scope"
        case .ready: return "checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .cameraUnavailable, .detectorUnavailable: return Theme.danger
        case .searching: return Theme.inkMuted
        case .aligning: return Theme.amber
        case .ready: return Theme.accent
        }
    }

    /// The detector runs and can show what it sees (camera and model both available).
    var isDetecting: Bool { self != .cameraUnavailable && self != .detectorUnavailable }
}

/// Shows the source's live view. Only one container shows it at a time; the view moves
/// into whichever container joined a window last.
struct DetectionPreview: UIViewRepresentable {
    let source: DartDetectionSource

    func makeUIView(context: Context) -> PreviewContainer {
        let container = PreviewContainer()
        container.preview = source.makePreviewView()
        return container
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {}

    final class PreviewContainer: UIView {
        var preview: UIView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let preview else { return }
            if preview.superview !== self {
                preview.removeFromSuperview()
                addSubview(preview)
            }
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            preview?.frame = bounds
        }
    }
}

/// Small live view in the game's top bar; its outline shows the board status.
struct CameraTile: View {
    let source: DartDetectionSource
    let status: BoardStatus
    var isHidden = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if status == .cameraUnavailable {
                    Theme.surfaceRaised
                    Image(systemName: status.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                } else if !isHidden {
                    DetectionPreview(source: source)
                        .allowsHitTesting(false)
                } else {
                    Color.black
                }
            }
            .frame(width: 66, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(status.tint, lineWidth: status == .ready ? 2.5 : 2)
            }
            .overlay(alignment: .bottomLeading) {
                if status != .cameraUnavailable {
                    Image(systemName: status.symbol)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(status.tint == Theme.inkMuted ? Color.black.opacity(0.6) : status.tint, in: Circle())
                        .offset(x: -6, y: 6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera, \(status.title)")
        .accessibilityHint("Shows the camera full screen")
    }
}

/// Full-screen camera view for positioning the phone. With a detector that offers it, a toggle
/// shows what the detector sees (`DetectorDebugOverlay`).
struct CameraFramingView: View {
    let source: DartDetectionSource
    let status: BoardStatus
    var onClose: () -> Void

    /// Remembered across launches; also settable with the `-detectorDebugOverlay YES` launch argument.
    @AppStorage("detectorDebugOverlay") private var showsDetectorView = false

    private var debugModel: DetectorDebugModel? { source.debugModel }
    private var detectorViewShown: Bool { showsDetectorView && debugModel != nil && status.isDetecting }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if status != .cameraUnavailable {
                DetectionPreview(source: source)
                    .ignoresSafeArea()
            }

            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if detectorViewShown, let debugModel {
                DetectorDebugOverlay(model: debugModel)
            } else {
                guide
                    .allowsHitTesting(false)
            }

            VStack {
                HStack(alignment: .top) {
                    if let debugModel, status.isDetecting {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                withAnimation(.snappy) { showsDetectorView.toggle() }
                            } label: {
                                Image(systemName: "dot.viewfinder")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(showsDetectorView ? Theme.accent : Color.white.opacity(0.18), in: Circle())
                            }
                            .accessibilityLabel("Detector view")
                            .accessibilityValue(showsDetectorView ? "On" : "Off")
                            .accessibilityHint("Shows what the detector sees")

                            if detectorViewShown {
                                DetectorDebugPanel(model: debugModel)
                                    .transition(.opacity)
                            }
                        }
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .accessibilityLabel("Close camera")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer()

                Label(status.title, systemImage: status.symbol)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 48)
                    .background(statusFill, in: Capsule())
                    .padding(.bottom, 28)
                    .contentTransition(.opacity)
                    .animation(.snappy, value: status)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { debugModel?.isShown = detectorViewShown }
        .onDisappear { debugModel?.isShown = false }
        .onChange(of: detectorViewShown) { _, shown in debugModel?.isShown = shown }
    }

    private var statusFill: Color {
        status == .searching ? Color.white.opacity(0.2) : status.tint
    }

    /// A ring that marks where the board should sit.
    private var guide: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.78
            Circle()
                .strokeBorder(status == .ready ? Theme.accent : Color.white.opacity(0.7),
                              style: StrokeStyle(lineWidth: status == .ready ? 3 : 2, dash: status == .ready ? [] : [10, 8]))
                .frame(width: side, height: side)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .animation(.snappy, value: status)
        }
        .ignoresSafeArea()
    }
}

/// Camera check before a game, opened from the home screen.
struct CameraCheckView: View {
    @StateObject private var holder: SourceHolder
    var onClose: () -> Void

    /// `makeSource` runs once for the lifetime of this view.
    init(makeSource: @escaping () -> DartDetectionSource, onClose: @escaping () -> Void) {
        _holder = StateObject(wrappedValue: SourceHolder(source: makeSource()))
        self.onClose = onClose
    }

    var body: some View {
        CameraFramingView(source: holder.source, status: holder.status, onClose: onClose)
            .onAppear { holder.start() }
            .onDisappear { holder.source.stop() }
            .keepsScreenAwake()
    }

    @MainActor
    final class SourceHolder: ObservableObject {
        let source: DartDetectionSource
        @Published var status: BoardStatus

        init(source: DartDetectionSource) {
            self.source = source
            self.status = source.status
        }

        func start() {
            source.onEvent = { [weak self] event in
                if case .status(let status) = event { self?.status = status }
            }
            status = source.status
            source.start()
        }
    }
}
