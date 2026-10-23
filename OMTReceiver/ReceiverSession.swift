import AVFoundation
import Combine
import Foundation
import OSLog
import UIKit

/// A single independently owned receive/playback pipeline. A future multiview
/// layout can retain several sessions without changing the transport or decoder.
@MainActor
final class ReceiverSession: ObservableObject {
    enum Phase: Equatable {
        case idle, connecting, waitingForVideo, playing, reconnecting, suspended
    }

    enum Overlay { case controls, sources, hidden }

    @Published private(set) var playback = ReceiverPlayback()
    private let benchmark = ReceiverBenchmark.makeIfRequested()
    private var benchmarkStarted = false
    private let applicationResources: ReceiverApplicationResources
    private let logger = Logger(subsystem: "com.suku.OMTReceiver", category: "ReceiverSession")
    private var resourceLeaseID: UUID?
    private var activationTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    @Published private(set) var phase: Phase = .idle {
        didSet { benchmark?.setPhase(String(describing: phase)) }
    }
    @Published private(set) var sourceName = ""
    @Published private(set) var message: String?
    @Published private(set) var statistics = ""
    @Published private(set) var isInterlaced = false
    @Published var fieldOrder: ReceiverFieldOrder = .topFirst {
        didSet {
            guard fieldOrder != oldValue, hasSelection else { return }
            reconnect()
        }
    }
    @Published private(set) var overlay: Overlay = .controls
    var controlsVisible: Bool { overlay == .controls }
    var sourcesVisible: Bool { overlay == .sources }
    @Published var diagnosticsVisible = false
    @Published var muted = false {
        didSet { playback.setMuted(muted) }
    }
    @Published var quality: OMTQuality = .default {
        didSet { connection?.sendQuality(quality) }
    }

    var hasSelection: Bool { selectedSource != nil }
    var isPlaying: Bool { phase == .playing }
    var status: String {
        switch phase {
        case .idle: return "Choose an OMT source"
        case .connecting: return "Connecting…"
        case .waitingForVideo: return "Connected · waiting for video"
        case .playing: return "Playing"
        case .reconnecting: return "Reconnecting…"
        case .suspended: return "Playback suspended"
        }
    }

    @Published private(set) var selectedSource: OMTSource?
    private var connection: OMTConnection?
    private var ingress: ReceiverIngress?
    private var generation = UUID()
    private var retryCount = 0
    private var retryTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var resumeAfterBackground = false
    private var audioInterrupted = false
    private var isForeground = true
    private var notificationObservers: [NSObjectProtocol] = []
    private var framesReceived = 0
    private var ingressSkipped = 0
    private var bytesReceived = 0
    private var metricsBegan = Date()
    private var lastInfo: VideoPlaybackInfo?

    init(applicationResources: ReceiverApplicationResources) {
        self.applicationResources = applicationResources
        observeAudioLifecycle()
        configurePlaybackCallbacks()
    }

    func startBenchmarkIfRequested() {
        guard !benchmarkStarted, let benchmark else { return }
        benchmarkStarted = true
        connect(to: benchmark.configuration.source)
    }

    private func configurePlaybackCallbacks() {
        playback.onError = { [weak self] error in self?.failed(error) }
        playback.onVideoPresented = { [weak self] info in
            guard let self, self.connection != nil else { return }
            self.lastInfo = info
            if self.isInterlaced != info.isInterlaced { self.isInterlaced = info.isInterlaced }
            if self.phase != .playing {
                self.phase = .playing
                self.message = nil
                self.retryCount = 0
                self.hideControlsAfterDelay()
            }
        }
    }

    func connect(to source: OMTSource) {
        stopAttempt()
        selectedSource = source
        isInterlaced = false
        sourceName = source.name
        message = nil
        statistics = ""
        retryCount = 0
        overlay = .controls
        beginAttempt()
    }

    /// Browsing never calls this method. Re-selecting a live or pending source
    /// dismisses the switcher without retiring its transport or audio lease.
    func selectSource(_ source: OMTSource) {
        if selectedSource?.id == source.id, connection != nil || activationTask != nil {
            dismissOverlay()
            return
        }
        connect(to: source)
        dismissOverlay()
    }

    func disconnect() {
        selectedSource = nil
        isInterlaced = false
        resumeAfterBackground = false
        stopAttempt()
        sourceName = ""
        message = nil
        statistics = ""
        phase = .idle
        overlay = .controls
    }

    func reconnect() {
        guard selectedSource != nil else { return }
        stopAttempt()
        retryCount = 0
        beginAttempt()
    }

    func revealControls() {
        hideTask?.cancel()
        overlay = .controls
    }

    func revealSources() {
        hideTask?.cancel()
        overlay = hasSelection ? .sources : .controls
    }

    func dismissOverlay() {
        guard hasSelection else { return }
        hideTask?.cancel()
        overlay = .hidden
    }

    func hideControls() {
        guard isPlaying else { return }
        dismissOverlay()
    }

    func suspend() {
        isForeground = false
        resumeAfterBackground = selectedSource != nil
        guard resumeAfterBackground else { return }
        stopAttempt()
        phase = .suspended
    }

    func resume() {
        isForeground = true
        guard resumeAfterBackground, !audioInterrupted, selectedSource != nil else { return }
        resumeAfterBackground = false
        beginAttempt()
    }

    private func beginAttempt() {
        guard let source = selectedSource, connection == nil, activationTask == nil else { return }
        guard isForeground, !audioInterrupted else { phase = .suspended; return }
        let attempt = UUID()
        let lease = UUID()
        generation = attempt
        resourceLeaseID = lease
        phase = retryCount == 0 ? .connecting : .reconnecting
        let resources = applicationResources, previousRelease = releaseTask
        activationTask = Task { [weak self, resources] in
            // A new attempt waits for its own previous retirement, without
            // blocking MainActor or another receiver's existing audio lease.
            if let previousRelease { await previousRelease.value }
            do {
                try Task.checkCancellation()
                try await resources.acquire(lease)
            } catch {
                guard let self, self.generation == attempt, self.resourceLeaseID == lease else { return }
                self.activationTask = nil
                self.resourceLeaseID = nil
                guard !(error is CancellationError) else { return }
                self.message = "Audio output could not start: \(error.localizedDescription)"
                self.phase = .idle
                self.overlay = .sources
                return
            }
            guard !Task.isCancelled, let self, self.generation == attempt,
                  self.resourceLeaseID == lease, self.selectedSource == source,
                  self.isForeground, !self.audioInterrupted else {
                await resources.release(lease)
                return
            }
            self.activationTask = nil
            self.startTransport(source: source, attempt: attempt, lease: lease)
        }
    }

    private func startTransport(source: OMTSource, attempt: UUID, lease: UUID) {
        // AVFoundation renderers belong to this connection attempt. A fresh
        // graph also recovers a media-services reset or an interrupted timebase.
        playback.onError = nil
        playback.onVideoPresented = nil
        benchmark?.beganAttempt()
        playback = ReceiverPlayback(benchmark: benchmark, fieldOrder: fieldOrder)
        playback.setMuted(muted)
        configurePlaybackCallbacks()
        framesReceived = 0
        ingressSkipped = 0
        bytesReceived = 0
        lastInfo = nil
        metricsBegan = Date()
        let inbox = ReceiverIngress { [weak self] packets, received, bytes, overflowed in
            guard let self, self.generation == attempt, self.connection != nil else { return }
            if overflowed {
                self.failed("The audio receive queue overflowed. Check the source or network connection.")
                return
            }
            self.benchmark?.network(videoReceived: received, bytes: bytes, skipped: max(0, received - 1))
            self.framesReceived += received
            self.ingressSkipped += max(0, received - 1)
            self.bytesReceived += bytes
            for packet in packets {
                switch packet {
                case .video(let frame): self.playback.enqueue(video: frame)
                case .audio(let frame): self.playback.enqueue(audio: frame)
                case .metadata: break
                }
            }
        }
        ingress = inbox
        let transport = OMTConnection(endpoint: source.endpoint, onPacket: { [weak inbox] packet in
            inbox?.submit(packet)
        }, onState: { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt, self.connection != nil else { return }
                switch state {
                case .connecting: break
                case .connected:
                    if self.phase != .playing { self.phase = .waitingForVideo }
                    self.applicationResources.setReceiving(true, for: lease)
                case .failed(let error): self.failed(error)
                case .disconnected: self.failed("The source closed the connection.")
                }
            }
        })
        connection = transport
        transport.sendQuality(quality)
        transport.setTally(program: true)
        transport.start()
        startMetrics(attempt: attempt)
    }

    private func failed(_ error: String) {
        guard selectedSource != nil, connection != nil else { return }
        benchmark?.failed(error)
        logger.error("OMT receive attempt failed: \(error, privacy: .public)")
        stopAttempt()
        message = error
        phase = .reconnecting
        if overlay == .hidden { overlay = .sources }
        retryCount = min(retryCount + 1, 5)
        let delay = min(1 << (retryCount - 1), 10)
        let attempt = generation
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == attempt, self.selectedSource != nil else { return }
            self.beginAttempt()
        }
    }

    private func stopAttempt() {
        generation = UUID()
        activationTask?.cancel(); activationTask = nil
        retryTask?.cancel(); retryTask = nil
        hideTask?.cancel(); hideTask = nil
        metricsTask?.cancel(); metricsTask = nil
        ingress?.invalidate(); ingress = nil
        connection?.stop(); connection = nil
        playback.reset()
        if let lease = resourceLeaseID {
            resourceLeaseID = nil
            let resources = applicationResources, previousRelease = releaseTask
            resources.setReceiving(false, for: lease)
            releaseTask = Task {
                if let previousRelease { await previousRelease.value }
                await resources.release(lease)
            }
        }
    }

    private func hideControlsAfterDelay() {
        hideTask?.cancel()
        guard overlay == .controls else { return }
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.isPlaying, self.overlay == .controls else { return }
            self.overlay = .hidden
        }
    }

    private func startMetrics(attempt: UUID) {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == attempt else { return }
                let elapsed = max(Date().timeIntervalSince(self.metricsBegan), 0.001)
                let mbps = Double(self.bytesReceived) * 8 / elapsed / 1_000_000
                if let info = self.lastInfo {
                    self.statistics = String(format: "%d × %d%@ · %.1f fps submitted · %.1f Mbps · %.2f ms decode · %d source frames skipped",
                        info.width, info.height, info.isInterlaced ? " interlaced" : "", Double(info.framesDecoded) / elapsed, mbps,
                        info.decodeMilliseconds, info.framesDropped + UInt64(self.ingressSkipped))
                } else {
                    self.statistics = String(format: "%.1f Mbps received · waiting for a supported video frame", mbps)
                }
            }
        }
    }

    /// An interruption can stop AVSampleBufferRenderSynchronizer without a
    /// background scene transition. Rebuild the same source after it ends rather
    /// than leaving a stopped timebase attached to a live socket.
    func audioInterruptionBegan() {
        guard !audioInterrupted else { return }
        audioInterrupted = true
        guard selectedSource != nil else { return }
        stopAttempt()
        phase = .suspended
        message = "Playback paused by a system audio interruption."
        if overlay == .hidden { overlay = .sources }
    }

    func audioInterruptionEnded(shouldResume: Bool) {
        guard audioInterrupted else { return }
        audioInterrupted = false
        guard selectedSource != nil else { return }
        guard shouldResume else {
            resumeAfterBackground = false
            message = "Audio was interrupted. Choose Reconnect to resume."
            return
        }
        if isForeground { beginAttempt() }
        else { resumeAfterBackground = true }
    }

    func audioServicesReset() {
        guard selectedSource != nil else { return }
        stopAttempt()
        if isForeground, !audioInterrupted { beginAttempt() }
        else { resumeAfterBackground = true; phase = .suspended }
    }

    private func observeAudioLifecycle() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
                let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if type == AVAudioSession.InterruptionType.began.rawValue {
                        self.audioInterruptionBegan()
                    } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                        self.audioInterruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
                    }
                }
            })
        notificationObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.audioServicesReset() }
            })
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        retryTask?.cancel()
        activationTask?.cancel()
        hideTask?.cancel()
        metricsTask?.cancel()
        ingress?.invalidate()
        connection?.stop()
        if let lease = resourceLeaseID {
            let resources = applicationResources, previousRelease = releaseTask
            Task { @MainActor in
                if let previousRelease { await previousRelease.value }
                await resources.release(lease)
            }
        }
    }
}

/// Coalesces delivery to the main actor. A busy UI cannot accumulate one Task
/// per network packet. Audio overflow is reported instead of losing samples.
private final class ReceiverIngress: @unchecked Sendable {
    typealias Delivery = @MainActor ([OMTPacket], Int, Int, Bool) -> Void
    private let lock = NSLock()
    private let delivery: Delivery
    private var audio: [OMTPacket] = []
    private var video: OMTPacket?
    private var videoCount = 0
    private var bytes = 0
    private var overflowed = false
    private var scheduled = false
    private var valid = true

    init(delivery: @escaping Delivery) { self.delivery = delivery }

    func submit(_ packet: OMTPacket) {
        lock.lock()
        guard valid else { lock.unlock(); return }
        switch packet {
        case .video(let frame):
            video = packet; videoCount += 1; bytes += frame.payload.count
        case .audio(let frame):
            bytes += frame.payload.count
            if audio.count < 16 { audio.append(packet) } else { overflowed = true }
        case .metadata: break
        }
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule {
            DispatchQueue.main.async { [weak self] in self?.drain() }
        }
    }

    func invalidate() {
        lock.lock(); valid = false; audio.removeAll(); video = nil; lock.unlock()
    }

    @MainActor private func drain() {
        lock.lock()
        guard valid else { scheduled = false; lock.unlock(); return }
        var packets = audio
        if let video { packets.append(video) }
        let count = videoCount, receivedBytes = bytes, overflow = overflowed
        audio.removeAll(keepingCapacity: true); video = nil
        videoCount = 0; bytes = 0; overflowed = false; scheduled = false
        lock.unlock()
        delivery(packets, count, receivedBytes, overflow)
    }
}
