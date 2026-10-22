import CoreMedia
import Foundation

/// Coherent sender timestamps retain their common 100 ns A/V mapping, never
/// this device's wall-clock origin. Independently generated lane origins are
/// rebased by arrival onto one local timebase with network and audio-route lead.
struct ReceiverTimeline {
    /// Network/decode headroom, in addition to the native audio output horizon.
    static let delay: Double = 0.120
    let playoutDelay: Double

    init(audioOutputLatency: Double = 0, ioBufferDuration: Double = 0) {
        // The synchronizer follows the audible audio clock. HDMI's output
        // pipeline consumes samples ahead of that clock, so a network-only
        // lead can enqueue valid PCM after its hardware rendering deadline.
        playoutDelay = Self.delay + max(0, audioOutputLatency) + max(0, ioBufferDuration)
    }
    enum Lane: Hashable { case video, audio }
    struct Mapping {
        let presentationTime: CMTime
        let globalReset: Bool
        let laneReset: Bool
        let hostAnchor: Double
    }
    private struct LaneState {
        var correction: Double
        var lastTimestamp: Int64
    }
    private var senderAnchor: Int64?
    private var hostAnchor: Double = 0
    private var lanes: [Lane: LaneState] = [:]

    mutating func reset() { senderAnchor = nil; hostAnchor = 0; lanes.removeAll() }

    mutating func map(_ timestamp: Int64, lane: Lane, hostNow: Double) throws -> Mapping {
        guard timestamp >= 0, hostNow.isFinite else { throw PlaybackFailure.invalidTimestamp }
        let globalReset = senderAnchor == nil
        if globalReset {
            senderAnchor = timestamp; hostAnchor = hostNow
        }
        let difference = timestamp - senderAnchor!
        let baseTime = Double(difference) / 10_000_000 + playoutDelay
        let elapsed = hostNow - hostAnchor
        let previous = lanes[lane]
        var correction = previous?.correction ?? 0
        let lead = baseTime + correction - elapsed
        let movedBackward = previous.map { timestamp < $0.lastTimestamp } ?? false
        var laneReset = false
        if !globalReset && (movedBackward || lead < -0.250 || lead > max(0.750, playoutDelay + 0.250)) {
            // The official OMT sender can independently auto-generate a zero
            // origin for each media lane. Late audio must not repeatedly reset
            // healthy video. Retain coherent shared PTS when possible; otherwise
            // rebase only this lane by arrival time, with no claim of recovering
            // synchronization that the source did not encode in its timestamps.
            correction = elapsed + playoutDelay - baseTime
            laneReset = true
        }
        lanes[lane] = .init(correction: correction, lastTimestamp: timestamp)
        return .init(presentationTime: CMTime(seconds: baseTime + correction, preferredTimescale: 10_000_000),
                     globalReset: globalReset, laneReset: laneReset, hostAnchor: hostAnchor)
    }
}

enum PlaybackFailure: LocalizedError {
    case invalidTimestamp
    case unsupportedVideo
    case malformedVideo(Int)
    case malformedAudio
    case allocation
    case audioOverrun

    var errorDescription: String? {
        switch self {
        case .invalidTimestamp: return "The source sent an invalid media timestamp."
        case .unsupportedVideo: return "This receiver supports progressive, 8-bit SDR VMX video up to 1920 × 1080 at 60 fps."
        case .malformedVideo(let code): return "The source sent an invalid VMX video frame (\(code))."
        case .malformedAudio: return "The source sent invalid FPA1 audio."
        case .allocation: return "The receiver could not allocate a media buffer."
        case .audioOverrun: return "Audio exceeded the receiver's bounded playback queue. Reconnect to the source."
        }
    }
}
