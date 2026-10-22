import AVFoundation
import Combine
import CoreMedia
import Foundation

struct VideoPlaybackInfo: Sendable {
    let width: Int
    let height: Int
    let fps: Double
    let decodeMilliseconds: Double
    let framesDecoded: UInt64
    let framesDropped: UInt64
}

/// One receiver owns one decoder, display, audio renderer and A/V timebase.
/// Network callbacks hand off compressed data; no decoding runs on MainActor.
@MainActor
final class ReceiverPlayback: ObservableObject {
    let displayLayer: AVSampleBufferDisplayLayer
    var onError: ((String) -> Void)?
    /// Reports samples admitted to the display renderer, not physical HDMI
    /// presentation or end-to-end latency measurements.
    var onVideoPresented: ((VideoPlaybackInfo) -> Void)?
    private let worker: ReceiverPlaybackWorker
    private var generation: UInt64 = 0

    init(benchmark: ReceiverBenchmark? = nil) {
        let display = AVSampleBufferDisplayLayer()
        display.videoGravity = .resizeAspect
        display.backgroundColor = CGColor(gray: 0, alpha: 1)
        display.isOpaque = true
        displayLayer = display
        worker = ReceiverPlaybackWorker(display: display, benchmark: benchmark)
        worker.onError = { [weak self] token, message in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onError?(message)
            }
        }
        worker.onVideo = { [weak self] token, info in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onVideoPresented?(info)
            }
        }
    }

    func enqueue(video: OMTVideoFrame) { worker.enqueue(video: video, generation: generation) }
    func enqueue(audio: OMTAudioFrame) { worker.enqueue(audio: audio, generation: generation) }
    func reset() { generation = worker.reset() }
    func setMuted(_ muted: Bool) { worker.setMuted(muted) }
    deinit { worker.shutdown() }
}

/// A coalescing dispatch source feeds one active decode and a bounded compressed
/// video queue. Video is decoded near its PTS, keeping native future queues small.
/// Audio is FIFO, limited to sixteen packets AND 300 ms. Readiness retries
/// have at most one outstanding callback. Neither lane can build a closure queue.
private final class ReceiverPlaybackWorker: @unchecked Sendable {
    var onError: (@Sendable (UInt64, String) -> Void)?
    var onVideo: (@Sendable (UInt64, VideoPlaybackInfo) -> Void)?
    private let queue = DispatchQueue(label: "OMTReceiver.playback", qos: .userInitiated)
    private let lock = NSLock()
    private let signal: DispatchSourceUserDataAdd
    private var generation: UInt64 = 0
    private var video: ReceiverVideoQueue
    private var audio: [OMTAudioFrame] = []
    private var audioDuration: Double = 0
    private var pendingReset = false
    private var pendingFailure: String?
    private var stopped = false
    private var failed = false
    private var muted = false
    private var dropped: UInt64 = 0
    // Worker queue only below this line.
    private let display: AVSampleBufferDisplayLayer
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let decoder = VMXFrameDecoder()
    private var timeline: ReceiverTimeline
    private var retryScheduled = false
    private var lastInfoHost: Double = -.infinity
    private var lastVideoTimestamp: Int64?
    private var lastAudioTimestamp: Int64?
    private var decoded: UInt64 = 0
    private let audioProbe = HardwareAudioProbe.makeIfRequested()
    private let benchmark: ReceiverBenchmark?

    init(display: AVSampleBufferDisplayLayer, benchmark: ReceiverBenchmark?) {
        self.display = display
        self.benchmark = benchmark
        // ReceiverSession creates this graph after its audio-session lease is
        // active, when the route reports the actual output and I/O latency.
        let session = AVAudioSession.sharedInstance()
        let clock = ReceiverTimeline(audioOutputLatency: session.outputLatency,
                                     ioBufferDuration: session.ioBufferDuration)
        timeline = clock
        video = ReceiverVideoQueue(playoutDelay: clock.playoutDelay)
        benchmark?.attach(display: display, nominalLead: timeline.playoutDelay,
                          outputLatency: session.outputLatency, ioDuration: session.ioBufferDuration)
        signal = DispatchSource.makeUserDataAddSource(queue: queue)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(display)
        synchronizer.addRenderer(audioRenderer)
        signal.setEventHandler { [weak self] in self?.drain() }
        signal.resume()
    }

    func enqueue(video: OMTVideoFrame, generation token: UInt64) {
        lock.lock()
        if !stopped, !failed, generation == token {
            let skipped = self.video.append(video)
            dropped &+= UInt64(skipped)
            benchmark?.skippedVideo(skipped)
        }
        lock.unlock()
        signal.add(data: 1)
    }

    func enqueue(audio frame: OMTAudioFrame, generation token: UInt64) {
        lock.lock()
        if !stopped, !failed, generation == token {
            let duration = Double(frame.samplesPerChannel) / Double(max(1, frame.sampleRate))
            if duration <= 0 || !duration.isFinite || audio.count >= 16 || audioDuration + duration > 0.300 {
                pendingFailure = PlaybackFailure.audioOverrun.localizedDescription
            } else {
                audio.append(frame); audioDuration += duration
            }
        }
        lock.unlock()
        signal.add(data: 1)
    }

    func reset() -> UInt64 {
        lock.lock()
        generation &+= 1
        let token = generation
        video.removeAll(); audio.removeAll(); audioDuration = 0
        pendingFailure = nil; pendingReset = true; failed = false; dropped = 0
        lock.unlock()
        signal.add(data: 1)
        return token
    }

    func setMuted(_ value: Bool) {
        lock.lock(); muted = value; lock.unlock()
        signal.add(data: 1)
    }

    func shutdown() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true; generation &+= 1
        video.removeAll(); audio.removeAll(); audioDuration = 0
        lock.unlock()
        signal.cancel()
        // Native worker retirement (including codec threads) never blocks UI.
        queue.async { [self] in flush(removeImage: true); decoder.reset() }
    }

    private func flush(removeImage: Bool) {
        synchronizer.setRate(0, time: .zero)
        if removeImage { display.flushAndRemoveImage() } else { display.flush() }
        audioRenderer.flush()
        timeline.reset(); lastVideoTimestamp = nil; lastAudioTimestamp = nil
        lastInfoHost = -.infinity; decoded = 0
    }

    private func admitted(_ token: UInt64, videoID: UInt64? = nil, _ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !failed, generation == token else { return false }
        if let videoID, !video.consumeFirst(matching: videoID) { return false }
        body()
        return true
    }

    private func drain() {
        lock.lock()
        let token = generation, reset = pendingReset, isStopped = stopped, failure = pendingFailure, isMuted = muted
        pendingReset = false; pendingFailure = nil
        let isFailed = failed
        lock.unlock()
        guard !isStopped else { return }
        if reset { flush(removeImage: true); decoder.reset() }
        audioRenderer.isMuted = isMuted
        if let failure { fail(failure, token: token); return }
        guard !isFailed else { return }
        if display.status == .failed {
            fail(display.error?.localizedDescription ?? "The video renderer stopped.", token: token); return
        }
        if audioRenderer.status == .failed {
            fail(audioRenderer.error?.localizedDescription ?? "The audio renderer stopped.", token: token); return
        }
        // Audio has a deadline; service its bounded backlog before video work.
        for _ in 0..<8 {
            guard audioRenderer.isReadyForMoreMediaData else { break }
            lock.lock()
            let frame = generation == token && !audio.isEmpty ? audio.removeFirst() : nil
            if let frame { audioDuration = max(0, audioDuration - Double(frame.samplesPerChannel) / Double(max(1, frame.sampleRate))) }
            lock.unlock()
            guard let frame else { break }
            do {
                if lastAudioTimestamp == frame.timestamp { continue }
                let time = try map(frame.timestamp, lane: .audio)
                let sample = try FPA1AudioDecoder.makeSample(frame, at: time)
                guard admitted(token, { audioRenderer.enqueue(sample) }) else { return }
                audioProbe?.admitted(frame: frame, sample: sample,
                    lead: time.seconds - synchronizer.currentTime().seconds,
                    rendererStatus: audioRenderer.status.rawValue, nominalLead: timeline.playoutDelay)
                benchmark?.audio(timestamp: frame.timestamp, samples: frame.samplesPerChannel, rate: frame.sampleRate,
                                 lead: time.seconds - synchronizer.currentTime().seconds)
                lastAudioTimestamp = frame.timestamp
            } catch { fail(error.localizedDescription, token: token); return }
        }
        // A bounded two-picture burst catches up after a delayed wake without
        // monopolizing the worker or pushing audio behind an unbounded decode.
        for _ in 0..<2 {
            guard display.isReadyForMoreMediaData else { break }
            lock.lock()
            let entry = generation == token ? video.first : nil
            lock.unlock()
            guard let entry else { break }
            let frame = entry.frame
            do {
                // Zero/black/chroma pixels are real replacement frames and
                // pass through exactly the same path as every other picture.
                let begin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                let time = try map(frame.timestamp, lane: .video)
                let lead = time.seconds - synchronizer.currentTime().seconds
                guard lead <= ReceiverVideoQueue.decodeLead(playoutDelay: timeline.playoutDelay) else { break }
                guard let image = try decoder.decode(frame) else {
                    benchmark?.stalledPool()
                    scheduleRetry(); return
                }
                var description: CMVideoFormatDescription?
                guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: image, formatDescriptionOut: &description) == noErr,
                      let description else { throw PlaybackFailure.allocation }
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                    formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
                      let sample else { throw PlaybackFailure.allocation }
                // A VMX frame is self-contained. Duplicate timestamps need
                // a queue flush before replacement; AVFoundation forbids
                // duplicate PTS in one stream. Retain the visible old image.
                if lastVideoTimestamp == frame.timestamp { display.flush() }
                guard admitted(token, videoID: entry.id, { display.enqueue(sample) }) else { continue }
                lastVideoTimestamp = frame.timestamp
                decoded &+= 1
                let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                benchmark?.video(decodeMs: (now - begin) * 1000,
                                 lead: time.seconds - synchronizer.currentTime().seconds, timestamp: frame.timestamp,
                                 frameRateN: frame.frameRateN, frameRateD: frame.frameRateD)
                if now - lastInfoHost >= 0.250 {
                    lastInfoHost = now
                    lock.lock(); let count = dropped; lock.unlock()
                    onVideo?(token, .init(width: frame.width, height: frame.height,
                        fps: Double(frame.frameRateN) / Double(max(1, frame.frameRateD)),
                        decodeMilliseconds: (now - begin) * 1000, framesDecoded: decoded, framesDropped: count))
                }
            } catch { fail(error.localizedDescription, token: token); return }
        }
        lock.lock(); let pending = !video.isEmpty || !audio.isEmpty; lock.unlock()
        if pending { scheduleRetry() }
    }

    private func map(_ timestamp: Int64, lane: ReceiverTimeline.Lane) throws -> CMTime {
        let mapping = try timeline.map(timestamp, lane: lane, hostNow: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        if mapping.globalReset {
            // Same mapping for video and audio; never compare sender time with
            // this device's unrelated absolute host clock.
            display.flush(); audioRenderer.flush()
            lastAudioTimestamp = nil; lastVideoTimestamp = nil
            synchronizer.setRate(1, time: .zero,
                atHostTime: CMTime(seconds: mapping.hostAnchor, preferredTimescale: 1_000_000_000))
        } else if mapping.laneReset {
            audioProbe?.rebased(lane)
            benchmark?.rebased(lane)
            switch lane {
            case .video: display.flush(); lastVideoTimestamp = nil
            case .audio: audioRenderer.flush(); lastAudioTimestamp = nil
            }
        }
        return mapping.presentationTime
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false; self.drain()
        }
    }

    private func fail(_ message: String, token: UInt64) {
        lock.lock()
        guard !stopped, !failed, generation == token else { lock.unlock(); return }
        failed = true; video.removeAll(); audio.removeAll(); audioDuration = 0
        lock.unlock()
        flush(removeImage: true)
        decoder.reset()
        onError?(token, message)
    }
}


/// Explicit hardware-test instrumentation. It is disabled during ordinary use,
/// retains bounded counters and one sample preview, and exports into app caches.
private final class HardwareAudioProbe {
    private let destination: URL
    private var count = 0
    private var resets = 0
    private var videoResets = 0
    private var late = 0
    private var minimumLead = Double.infinity
    private var maximumGap = 0.0
    private var previousHost: Double?
    private var previousTimestamp: Int64?
    private var unexpectedTimestampSteps = 0
    private var lastWrite = -Double.infinity
    private var format: [String: Any] = [:]

    static func makeIfRequested() -> HardwareAudioProbe? {
        guard ProcessInfo.processInfo.environment["OMT_RECEIVER_DIAGNOSTICS"] == "1" else { return nil }
        return HardwareAudioProbe()
    }

    private init() {
        destination = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OMTHardwareAudio.json")
    }

    func rebased(_ lane: ReceiverTimeline.Lane) {
        if lane == .audio { resets += 1 } else { videoResets += 1 }
    }

    func admitted(frame: OMTAudioFrame, sample: CMSampleBuffer, lead: Double, rendererStatus: Int, nominalLead: Double) {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        count += 1
        if lead.isFinite { minimumLead = min(minimumLead, lead); if lead < 0 { late += 1 } }
        if let previousHost { maximumGap = max(maximumGap, now - previousHost) }
        if let previousTimestamp,
           abs(Double(frame.timestamp - previousTimestamp) / 10_000_000
               - Double(frame.samplesPerChannel) / Double(frame.sampleRate)) > 0.0001 {
            unexpectedTimestampSteps += 1
        }
        previousHost = now; previousTimestamp = frame.timestamp
        if format.isEmpty, let description = CMSampleBufferGetFormatDescription(sample),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            let session = AVAudioSession.sharedInstance()
            format = ["sampleRate": asbd.pointee.mSampleRate,
                      "flags": asbd.pointee.mFormatFlags,
                      "bytesPerFrame": asbd.pointee.mBytesPerFrame,
                      "channels": asbd.pointee.mChannelsPerFrame,
                      "bitsPerChannel": asbd.pointee.mBitsPerChannel,
                      "sampleCount": CMSampleBufferGetNumSamples(sample),
                      "totalBytes": CMSampleBufferGetTotalSampleSize(sample),
                      "firstTimestamp": frame.timestamp,
                      "sessionSampleRate": session.sampleRate,
                      "outputLatencyMs": session.outputLatency * 1000,
                      "ioBufferMs": session.ioBufferDuration * 1000,
                      "outputChannels": session.outputNumberOfChannels,
                      "route": session.currentRoute.outputs.map { $0.portType.rawValue }]
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var preview = [Float](repeating: 0, count: 16)
                let status = preview.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                if status == noErr { format["firstInterleavedSamples"] = preview }
            }
        }
        guard now - lastWrite >= 5 else { return }
        lastWrite = now
        let values: [String: Any] = ["audioPackets": count,
            "audioResets": resets, "videoResets": videoResets, "nominalLeadMs": nominalLead * 1000,
            "latePackets": late, "minimumLeadMs": minimumLead.isFinite ? minimumLead * 1000 : 0,
            "currentLeadMs": lead.isFinite ? lead * 1000 : 0,
            "maximumAdmissionGapMs": maximumGap * 1000,
            "unexpectedTimestampSteps": unexpectedTimestampSteps,
            "rendererStatus": rendererStatus, "format": format]
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination, options: .atomic)
        } catch { print("OMT hardware diagnostics write failed: \(error.localizedDescription)") }
    }
}
