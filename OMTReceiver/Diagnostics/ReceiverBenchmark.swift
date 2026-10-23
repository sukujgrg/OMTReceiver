import AVFoundation
import CoreMedia
import Darwin
import Foundation

/// Explicit command-line test mode. Ordinary launches and discovery never select
/// a source. A fresh UUID prevents reports from different launches being mixed.
struct ReceiverBenchmarkConfiguration {
    let runID: UUID
    let source: OMTSource

    static func parse(_ arguments: [String]) throws -> Self? {
        guard arguments.contains("--omt-benchmark-run") else { return nil }
        func value(_ key: String) throws -> String {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count,
                  arguments.filter({ $0 == key }).count == 1 else { throw ConfigurationError.invalid }
            return arguments[index + 1]
        }
        guard let id = UUID(uuidString: try value("--omt-benchmark-run")) else { throw ConfigurationError.invalid }
        return try Self(runID: id, source: OMTSource.manual(address: value("--omt-benchmark-source")))
    }

    enum ConfigurationError: LocalizedError {
        case invalid
        var errorDescription: String? { "Benchmark launch needs a fresh UUID and an explicit --omt-benchmark-source omt://host:port." }
    }
}

/// A fixed-size histogram. Percentiles are upper bounds at 0.25 ms resolution;
/// values above one second remain counted, with their exact minimum/maximum.
struct BenchmarkHistogram {
    private(set) var count: UInt64 = 0
    private var total = 0.0
    private var minimum = Double.infinity
    private var maximum = 0.0
    private var buckets = [UInt64](repeating: 0, count: 4002)

    mutating func record(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        count += 1; total += milliseconds
        minimum = min(minimum, milliseconds); maximum = max(maximum, milliseconds)
        let index = milliseconds > 1000 ? 4001 : Int(ceil(milliseconds * 4))
        buckets[index] += 1
    }

    func percentileUpperBound(_ quantile: Double) -> Double? {
        guard count > 0, quantile > 0, quantile <= 1 else { return nil }
        let rank = UInt64(ceil(Double(count) * quantile))
        var accumulated: UInt64 = 0
        for (index, value) in buckets.enumerated() {
            accumulated += value
            if accumulated >= rank { return index == 4001 ? nil : Double(index) / 4 }
        }
        return nil
    }

    var summary: [String: Any] {
        var values: [String: Any] = ["count": count, "overflowAbove1000ms": buckets[4001]]
        if count > 0 {
            values["mean"] = total / Double(count); values["minimum"] = minimum; values["maximum"] = maximum
            for (name, quantile) in [("p50UpperBound", 0.5), ("p95UpperBound", 0.95), ("p99UpperBound", 0.99)] {
                if let bound = percentileUpperBound(quantile) { values[name] = bound } else { values[name] = NSNull() }
            }
        }
        return values
    }
}

/// Optional per-session counters, including across reconnects. The playback
/// worker only updates bounded state under a short lock; file I/O and native
/// metric queries run on a separate serial queue, never on the playback worker.
final class ReceiverBenchmark: @unchecked Sendable {
    let configuration: ReceiverBenchmarkConfiguration
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "OMTReceiver.benchmark", qos: .utility)
    private let timer: DispatchSourceTimer
    private let latestURL: URL
    private let seriesURL: URL
    private let began = ProcessInfo.processInfo.systemUptime
    private let created = Date()
    private let instanceID = UUID().uuidString
    private var values: [String: Any] = [:]
    private var decode = BenchmarkHistogram()
    private var audioGaps = BenchmarkHistogram()
    private var lastAudioHost: Double?
    private var lastAudioTimestamp: Int64?
    private var lastAudioDuration: Double?
    private var minimumAudioLead = Double.infinity
    private var maximumAudioLead = -Double.infinity
    private var videoLead = 0.0
    private var videoFrames: UInt64 = 0
    private var videoSamples: UInt64 = 0
    private var audioPackets: UInt64 = 0
    private var lateAudio: UInt64 = 0
    private var shortAudioLead: UInt64 = 0
    private var timestampSteps: UInt64 = 0
    private var ingressSkipped: UInt64 = 0
    private var playbackSkipped: UInt64 = 0
    private var attempts: UInt64 = 0
    private var videoResets: UInt64 = 0
    private var audioResets: UInt64 = 0
    private var poolStalls: UInt64 = 0
    private var failures: [String] = []
    private var phase = "idle"
    private var routeHorizon = 0.0
    private var firstVideoHost: Double?
    private var route: [String: Any] = [:]
    private weak var renderer: AVSampleBufferVideoRenderer?
    private var rendererID = UUID()
    private var rendererMetrics: [String: Any] = [:]
    private var metricQueryPending = false
    // Export queue only.
    private var exports = 0
    private var previousExportHost: Double?
    private var previousCPU: Double?
    private var previousVideoFrames: UInt64 = 0
    private var previousVideoSamples: UInt64 = 0
    private var previousAudioPackets: UInt64 = 0

    static func makeIfRequested() -> ReceiverBenchmark? {
        do {
            guard let configuration = try ReceiverBenchmarkConfiguration.parse(ProcessInfo.processInfo.arguments) else { return nil }
            return try ReceiverBenchmark(configuration: configuration)
        } catch {
            print("OMT benchmark could not start: \(error.localizedDescription)")
            return nil
        }
    }

    init(configuration: ReceiverBenchmarkConfiguration, directory: URL? = nil) throws {
        self.configuration = configuration
        // tvOS permits cache storage, not the iOS Documents directory. Reports
        // are copied to the Mac while the app is active.
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OMTBenchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        latestURL = base.appendingPathComponent(configuration.runID.uuidString + ".json")
        seriesURL = base.appendingPathComponent(configuration.runID.uuidString + ".jsonl")
        // Reusing a run ID fails visibly rather than silently mixing evidence.
        try Data().write(to: seriesURL, options: .withoutOverwriting)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.export() }
        timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(100))
        timer.resume()
        print("OMT benchmark run \(configuration.runID.uuidString); reports: \(latestURL.path)")
    }

    func setPhase(_ value: String) { lock.withLock { phase = value } }

    func beganAttempt() {
        lock.withLock {
            attempts += 1; lastAudioHost = nil; lastAudioTimestamp = nil; lastAudioDuration = nil
        }
    }

    func failed(_ message: String) {
        lock.withLock {
            if failures.count < 8 { failures.append(message) }
            values["failureCount"] = (values["failureCount"] as? Int ?? 0) + 1
        }
    }

    func attach(renderer: AVSampleBufferVideoRenderer, nominalLead: Double, outputLatency: Double, ioDuration: Double) {
        lock.withLock {
            self.renderer = renderer; rendererID = UUID(); metricQueryPending = false
            rendererMetrics = [:]
            routeHorizon = outputLatency + ioDuration
            route = ["nominalLeadMs": nominalLead * 1000, "outputLatencyMs": outputLatency * 1000,
                     "ioBufferMs": ioDuration * 1000,
                     "sampleRate": AVAudioSession.sharedInstance().sampleRate,
                     "ports": AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }]
        }
    }

    func videoRendererState(_ state: [String: Any]) {
        lock.withLock { values["videoRendererState"] = state }
    }

    func network(videoReceived: Int, bytes: Int, skipped: Int) {
        lock.withLock {
            values["videoReceivedAfterTransportMailbox"] = (values["videoReceivedAfterTransportMailbox"] as? Int ?? 0) + videoReceived
            values["payloadBytesAfterTransportMailbox"] = (values["payloadBytesAfterTransportMailbox"] as? Int ?? 0) + bytes
            ingressSkipped += UInt64(max(0, skipped))
        }
    }

    func skippedVideo(_ count: Int = 1) { lock.withLock { playbackSkipped += UInt64(max(0, count)) } }
    func stalledPool() { lock.withLock { poolStalls += 1 } }
    func rebased(_ lane: ReceiverTimeline.Lane) { lock.withLock { if lane == .audio { audioResets += 1 } else { videoResets += 1 } } }

    func video(decodeMs: Double, lead: Double, timestamp: Int64, frameRateN: Int, frameRateD: Int,
               width: Int, height: Int, flags: UInt32,
               outputSamples: Int = 1, interlaced: Bool = false, fieldOrder: ReceiverFieldOrder = .topFirst) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if firstVideoHost == nil { firstVideoHost = now }
            decode.record(decodeMs); videoFrames += 1; videoLead = lead
            videoSamples += UInt64(max(0, min(2, outputSamples)))
            let fieldsPerFrame = interlaced && Double(frameRateN) / Double(max(1, frameRateD)) <= 30 ? 2 : 1
            values["videoSourceScanMode"] = interlaced ? "interlaced" : "progressive"
            values["videoOutputFrameRateNumerator"] = frameRateN * fieldsPerFrame
            values["videoOutputFrameRateDenominator"] = frameRateD
            values["videoDeinterlacePolicy"] = interlaced ? (fieldsPerFrame == 2 ? "bob-both-fields" : "bob-first-field") : "none"
            if interlaced { values["videoFieldOrder"] = fieldOrder.rawValue }
            else { values.removeValue(forKey: "videoFieldOrder") }
            values["videoFrameRateNumerator"] = frameRateN
            values["videoFrameRateDenominator"] = frameRateD
            values["videoWidth"] = width
            values["videoHeight"] = height
            values["videoSourceFlags"] = flags
            values["lastVideoSourceTimestamp100ns"] = timestamp
            values["lastVideoAdmissionUptime"] = now
        }
    }

    /// The first output sample is recorded with video(...); subsequent fields
    /// are counted at their own successful enqueue, including partial batches.
    func additionalVideoSample() { lock.withLock { videoSamples += 1 } }

    func audio(timestamp: Int64, samples: Int, rate: Int, channels: Int, activeChannels: UInt32, lead: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            audioPackets += 1
            values["audioSampleRate"] = rate
            values["audioChannels"] = channels
            values["audioActiveChannelsMask"] = activeChannels
            if let lastAudioHost { audioGaps.record((now - lastAudioHost) * 1000) }
            if let lastAudioTimestamp, let lastAudioDuration,
               abs(Double(timestamp - lastAudioTimestamp) / 10_000_000 - lastAudioDuration) > 0.0001 { timestampSteps += 1 }
            if lead.isFinite {
                minimumAudioLead = min(minimumAudioLead, lead); maximumAudioLead = max(maximumAudioLead, lead)
                if lead < 0 { lateAudio += 1 }
                if lead < routeHorizon { shortAudioLead += 1 }
                values["currentAudioLeadMs"] = lead * 1000
            }
            lastAudioHost = now; lastAudioTimestamp = timestamp; lastAudioDuration = Double(samples) / Double(max(1, rate))
        }
    }

    private func queryRenderer() {
        guard #available(tvOS 17.4, *) else { return }
        let query: (AVSampleBufferVideoRenderer, UUID)? = lock.withLock {
            guard !metricQueryPending, let renderer else { return nil }
            metricQueryPending = true
            return (renderer, rendererID)
        }
        guard let (renderer, token) = query else { return }
        renderer.loadVideoPerformanceMetrics { [weak self] metrics in
            guard let self else { return }
            self.lock.withLock {
                guard self.rendererID == token else { return }
                self.metricQueryPending = false
                if let metrics {
                    self.rendererMetrics = ["totalFrames": metrics.totalNumberOfFrames,
                        "droppedFrames": metrics.numberOfDroppedFrames,
                        "corruptedFrames": metrics.numberOfCorruptedFrames,
                        "accumulatedFrameDelayMs": metrics.totalAccumulatedFrameDelay * 1000,
                        "optimizedCompositingFrames": metrics.numberOfFramesDisplayedUsingOptimizedCompositing,
                        "sampledAtUptime": ProcessInfo.processInfo.systemUptime]
                }
            }
        }
    }

    private func export() {
        queryRenderer()
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot: (report: [String: Any], video: UInt64, videoSamples: UInt64, audio: UInt64) = lock.withLock {
            var report = values
            report.merge(["schemaVersion": 1, "runID": configuration.runID.uuidString,
                "instanceID": instanceID, "pid": ProcessInfo.processInfo.processIdentifier,
                "createdAt": ISO8601DateFormatter().string(from: created),
                "updatedAt": ISO8601DateFormatter().string(from: Date()), "uptime": now,
                "elapsedSeconds": now - began, "phase": phase, "attempts": attempts,
                "videoFramesAdmitted": videoFrames, "videoSamplesAdmitted": videoSamples, "audioPacketsAdmitted": audioPackets,
                "ingressCoalescedVideo": ingressSkipped, "playbackCoalescedVideo": playbackSkipped,
                "poolStalls": poolStalls, "videoTimelineResets": videoResets, "audioTimelineResets": audioResets,
                "decodeMs": decode.summary, "audioAdmissionGapMs": audioGaps.summary,
                "lateAudioPackets": lateAudio, "audioPacketsBelowRouteHorizon": shortAudioLead,
                "audioTimestampDiscontinuities": timestampSteps, "currentVideoLeadMs": videoLead * 1000,
                "route": route, "renderer": rendererMetrics, "failures": failures,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "measurement": "Receiver admission and native renderer metrics; excludes physical HDMI/panel latency"
            ], uniquingKeysWith: { _, new in new })
            if let firstVideoHost { report["secondsSinceFirstVideo"] = now - firstVideoHost }
            if minimumAudioLead.isFinite { report["minimumAudioLeadMs"] = minimumAudioLead * 1000 }
            if maximumAudioLead.isFinite { report["maximumAudioLeadMs"] = maximumAudioLead * 1000 }
            return (report, videoFrames, videoSamples, audioPackets)
        }
        var report = snapshot.report
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            report["cpuSeconds"] = cpu
            if let previousCPU, let previousExportHost, now > previousExportHost {
                report["cpuPercentOfOneCore"] = (cpu - previousCPU) / (now - previousExportHost) * 100
            }
            previousCPU = cpu
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        if status == KERN_SUCCESS { report["physicalFootprintMiB"] = Double(info.phys_footprint) / 1_048_576 }
        else { report["memoryReadKernelStatus"] = status }
        if let previousExportHost, now > previousExportHost {
            report["windowSeconds"] = now - previousExportHost
            report["windowVideoAdmissionFPS"] = Double(snapshot.video - previousVideoFrames) / (now - previousExportHost)
            report["windowVideoSampleFPS"] = Double(snapshot.videoSamples - previousVideoSamples) / (now - previousExportHost)
            report["windowAudioPacketsPerSecond"] = Double(snapshot.audio - previousAudioPackets) / (now - previousExportHost)
        }
        previousExportHost = now; previousVideoFrames = snapshot.video; previousVideoSamples = snapshot.videoSamples; previousAudioPackets = snapshot.audio
        report["exportSequence"] = exports
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try data.write(to: latestURL, options: .atomic)
            // Bounded to 3,000 five-second samples (four hours plus setup margin).
            // The latest report
            // continues updating, so a full series cannot masquerade as fresh.
            if exports < 3000 {
                let handle = try FileHandle(forWritingTo: seriesURL)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
            }
            exports += 1
        } catch { print("OMT benchmark export failed: \(error.localizedDescription)") }
    }

    deinit { timer.cancel() }
}
