import AVFoundation
import SwiftUI
import UIKit

struct ReceiverRootView: View {
    @ObservedObject var receiver: ReceiverSession
    @ObservedObject var discovery: OMTDiscovery
    @AppStorage("manualSourceAddress") private var address = ""
    @State private var manualError: String?
    @State private var showingManualEntry = false
    @FocusState private var videoFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(displayLayer: receiver.playback.displayLayer)
                .ignoresSafeArea()
                .accessibilityLabel("OMT video output")

            if receiver.isPlaying && !receiver.controlsVisible {
                Color.clear
                    .ignoresSafeArea()
                    .focusable()
                    .focused($videoFocused)
                    .focusEffectDisabled()
                    .accessibilityLabel("Video playing. Press Back to show controls.")
                    .accessibilityIdentifier("fullscreen-video")
                    .onAppear { videoFocused = true }
            }

            if receiver.controlsVisible || !receiver.isPlaying {
                controls
                    .transition(.opacity)
            }

            if receiver.diagnosticsVisible && !receiver.controlsVisible && receiver.isPlaying {
                VStack {
                    Spacer()
                    Text(receiver.statistics)
                        .font(.caption.monospacedDigit())
                        .padding(16)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(60)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: receiver.controlsVisible)
        .onExitCommand(perform: receiver.isPlaying ? {
            if receiver.controlsVisible { receiver.hideControls() }
            else { receiver.revealControls() }
        } : nil)
        .onPlayPauseCommand {
            if receiver.controlsVisible { receiver.hideControls() }
            else { receiver.revealControls() }
        }
        .onMoveCommand { _ in
            if !receiver.controlsVisible { receiver.revealControls() }
        }
        .sheet(isPresented: $showingManualEntry) { manualEntry }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("OMT Receiver", systemImage: "tv")
                        .font(.title2.weight(.semibold))
                    Text(receiver.sourceName.isEmpty ? receiver.status : receiver.sourceName)
                        .font(.headline)
                    if !receiver.sourceName.isEmpty {
                        Text(receiver.status).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if receiver.isPlaying {
                    Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                        receiver.hideControls()
                    }
                    .accessibilityIdentifier("fullscreen")
                }
            }

            if let message = receiver.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 60) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Sources").font(.headline)
                    if discovery.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(discovery.stateMessage ?? "Looking for OMT sources on your local network…")
                                .foregroundStyle(.secondary)
                            Text("Start an OMT sender on the same network, or enter its address.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(discovery.sources) { source in
                                    Button {
                                        manualError = nil
                                        receiver.connect(to: source)
                                    } label: {
                                        Label(source.name, systemImage: "network")
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .accessibilityHint("Connect and show this OMT source full screen")
                                    .accessibilityIdentifier("source-\(source.id)")
                                }
                            }
                            .padding(14)
                        }
                        .frame(height: min(320, CGFloat(discovery.sources.count) * 110 + 28))
                    }
                    Button("Enter Address…", systemImage: "keyboard") {
                        showingManualEntry = true
                    }
                    .accessibilityIdentifier("manual-address")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 24) {
                    Text("Playback").font(.headline)
                    Toggle("Mute audio", isOn: $receiver.muted)
                        .accessibilityIdentifier("mute-audio")
                    Text("Suggested quality").font(.callout).foregroundStyle(.secondary)
                    Picker("Quality", selection: $receiver.quality) {
                        ForEach(OMTQuality.allCases) { quality in
                            Text(quality == .default ? "Auto" : quality.rawValue)
                                .font(.callout)
                                .tag(quality)
                        }
                    }
                    Toggle("Show statistics", isOn: $receiver.diagnosticsVisible)
                    if receiver.hasSelection {
                        HStack(spacing: 20) {
                            Button("Reconnect") { receiver.reconnect() }
                            Button("Disconnect") { receiver.disconnect() }
                                .accessibilityIdentifier("disconnect")
                        }
                    }
                    Text("SDR · up to 1080p60 · Ethernet recommended")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 520, alignment: .leading)
            }

            if !receiver.statistics.isEmpty {
                Text(receiver.statistics)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("receiver-statistics")
            }
            Text("Press Back or Play/Pause to show or hide these controls during playback.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: 1550)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal, 70)
        .padding(.vertical, 45)
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Connect to an OMT source").font(.title2)
            TextField("omt://192.168.1.10:6400", text: $address)
                .accessibilityIdentifier("manual-source-address")
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { connectManually() }
            Text("Use the source’s TCP port, usually 6400–6600. A Mac hostname such as studio.local also works.")
                .font(.callout).foregroundStyle(.secondary)
            if let manualError {
                Text(manualError).foregroundStyle(.orange)
            }
            HStack(spacing: 24) {
                Button("Connect") { connectManually() }
                    .accessibilityIdentifier("connect-manual")
                Button("Cancel") { showingManualEntry = false }
            }
        }
        .frame(maxWidth: 950)
        .padding(60)
    }

    private func connectManually() {
        do {
            let source = try OMTSource.manual(address: address)
            manualError = nil
            receiver.connect(to: source)
            showingManualEntry = false
        } catch {
            manualError = error.localizedDescription
        }
    }
}

private struct VideoSurface: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.sampleLayer = displayLayer
        return view
    }

    func updateUIView(_ uiView: VideoSurfaceView, context: Context) {
        if uiView.sampleLayer !== displayLayer { uiView.sampleLayer = displayLayer }
    }

    final class VideoSurfaceView: UIView {
        var sampleLayer: AVSampleBufferDisplayLayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let sampleLayer { layer.addSublayer(sampleLayer) }
                setNeedsLayout()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sampleLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
