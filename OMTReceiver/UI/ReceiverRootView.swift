import AVFoundation
import SwiftUI
import UIKit

struct ReceiverRootView: View {
    @ObservedObject var receiver: ReceiverSession
    @ObservedObject var discovery: OMTDiscovery
    @StateObject private var sourcePreferences = ReceiverSourcePreferences()
    @AppStorage("manualSourceAddress") private var address = ""
    @State private var manualError: String?
    @State private var showingManualEntry = false
    @State private var showingInformation = false
    @FocusState private var videoFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(displayLayer: receiver.playback.displayLayer)
                .ignoresSafeArea()
                .accessibilityLabel("OMT video output")

            if receiver.hasSelection && receiver.overlay == .hidden {
                Color.clear
                    .ignoresSafeArea()
                    .focusable()
                    .focused($videoFocused)
                    .focusEffectDisabled()
                    .accessibilityLabel("\(receiver.status). Press Back to choose a source.")
                    .accessibilityIdentifier(receiver.isPlaying ? "fullscreen-video" : "connecting-video")
                    .onTapGesture { receiver.revealSources() }
                    .onAppear { videoFocused = true }
            }

            if receiver.controlsVisible {
                controls
                    .transition(.opacity)
            }

            if receiver.sourcesVisible {
                VStack {
                    Spacer()
                    ReceiverSourceSwitcher(receiver: receiver, discovery: discovery, preferences: sourcePreferences)
                }
                .padding(.horizontal, 70)
                .padding(.bottom, 45)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if receiver.overlay == .hidden && !receiver.isPlaying && receiver.hasSelection {
                VStack {
                    Spacer()
                    HStack(spacing: 18) {
                        ProgressView()
                        Text("\(receiver.sourceName) · \(receiver.status)").lineLimit(2)
                    }
                    .padding(24)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("connection-status")
                }
                .padding(60)
                .allowsHitTesting(false)
            }

            if receiver.diagnosticsVisible && receiver.overlay == .hidden && receiver.isPlaying {
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
        .animation(.easeInOut(duration: 0.2), value: receiver.overlay)
        .onExitCommand(perform: receiver.hasSelection && !showingManualEntry && !showingInformation ? {
            if receiver.sourcesVisible { receiver.dismissOverlay() }
            else { receiver.revealSources() }
        } : nil)
        .onPlayPauseCommand {
            guard !showingManualEntry, !showingInformation else { return }
            if receiver.overlay == .hidden { receiver.revealSources() }
            else { receiver.dismissOverlay() }
        }
        .onMoveCommand { _ in
            guard !showingManualEntry, !showingInformation else { return }
            if receiver.overlay == .hidden { receiver.revealSources() }
        }
        .sheet(isPresented: $showingManualEntry) { manualEntry }
        .fullScreenCover(isPresented: $showingInformation, onDismiss: { receiver.revealControls() }) { AppInformationView() }
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
                if receiver.hasSelection {
                    Button("Sources", systemImage: "rectangle.stack") { receiver.revealSources() }
                        .accessibilityIdentifier("show-sources")
                }
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
                                        receiver.selectSource(source)
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
                    Button("About", systemImage: "info.circle") {
                        receiver.revealControls()
                        showingInformation = true
                    }
                    .accessibilityIdentifier("about")
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
                    if receiver.isInterlaced {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Interlaced field order").font(.callout).foregroundStyle(.secondary)
                            Picker("Field order", selection: $receiver.fieldOrder) {
                                ForEach(ReceiverFieldOrder.allCases, id: \.self) { order in
                                    Text(order == .topFirst ? "Top first" : "Bottom first").tag(order)
                                }
                            }
                            .accessibilityIdentifier("interlaced-field-order")
                            .accessibilityHint("Reconnects using the selected field order. Change this if interlaced motion appears to step backward.")
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
            Text(receiver.hasSelection ? "Press Back to choose a source. Select Settings in the source strip to return here." : "Choose a source to start watching.")
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
            receiver.selectSource(source)
            showingManualEntry = false
        } catch {
            manualError = error.localizedDescription
        }
    }
}

private struct ReceiverSourceSwitcher: View {
    @ObservedObject var receiver: ReceiverSession
    @ObservedObject var discovery: OMTDiscovery
    @ObservedObject var preferences: ReceiverSourcePreferences
    @FocusState private var focusedSourceID: String?
    @Namespace private var sourceFocus

    private var sources: [OMTSource] {
        preferences.orderedSources(discovery.sources, selected: receiver.selectedSource)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sources").font(.headline)
                    Text("\(receiver.sourceName) · \(receiver.status)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let source = receiver.selectedSource {
                    Button {
                        preferences.toggleFavourite(source)
                    } label: {
                        Label(preferences.favourites.contains(source.id) ? "Unfavourite" : "Favourite",
                              systemImage: preferences.favourites.contains(source.id) ? "star.fill" : "star")
                    }
                    .accessibilityIdentifier("favourite-current-source")
                    .accessibilityHint("Changes the order of sources without interrupting playback")
                }
                Button("Settings", systemImage: "gearshape") { receiver.revealControls() }
                    .accessibilityIdentifier("switcher-settings")
                Button("Close", systemImage: "xmark") { receiver.dismissOverlay() }
                    .accessibilityIdentifier("switcher-close")
            }
            .focusSection()
            if let message = receiver.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).lineLimit(2)
                    .accessibilityIdentifier("switcher-error")
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 28) {
                        ForEach(sources) { source in
                            sourceButton(source)
                                .id(source.id)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 22)
                }
                .focusScope(sourceFocus)
                .task {
                    let target = receiver.selectedSource?.id ?? sources.first?.id
                    if let target { proxy.scrollTo(target, anchor: .center) }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    focusedSourceID = target
                }
                .onChange(of: sources.map(\.id)) { _, ids in
                    // Discovery can remove the focused, unselected advertisement.
                    // Restore a reachable item without changing playback.
                    if let focusedSourceID, !ids.contains(focusedSourceID) {
                        self.focusedSourceID = receiver.selectedSource?.id ?? ids.first
                    }
                }
            }
            Text("Select to switch · Back to return to video · Favourite the current source to keep it near the front")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("source-switcher")
    }

    private func sourceButton(_ source: OMTSource) -> some View {
        let selected = receiver.selectedSource?.id == source.id
        return Button { receiver.selectSource(source) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "network")
                    Spacer()
                    if preferences.favourites.contains(source.id) { Image(systemName: "star.fill") }
                }
                Text(source.name).font(.headline).lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Text(selected ? receiver.status : "Select to watch")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 320, height: 160, alignment: .leading)
        }
        .focused($focusedSourceID, equals: source.id)
        .prefersDefaultFocus(selected, in: sourceFocus)
        .accessibilityLabel(source.name)
        .accessibilityValue(selected ? "Current source · \(receiver.status)" : "Available source")
        .accessibilityHint(selected ? "Return to this source" : "Switch picture and audio to this source")
        .accessibilityIdentifier("quick-source-\(source.id)")
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
