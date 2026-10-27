import CoreMedia
import Foundation

/// OMT has no field-dominance flag. Top-first is an explicit default convention;
/// senders with bottom-first temporal order can be selected before connecting.
enum ReceiverFieldOrder: String, CaseIterable, Sendable {
    case topFirst
    case bottomFirst

    var firstField: Int { self == .topFirst ? 0 : 1 }
}

/// Presentation offsets are rational fractions of one complete OMT frame.
/// No sender timestamp or shared audio mapping is rewritten to double field rate.
struct ReceiverVideoCadence {
    struct Sample {
        /// Nil means the original progressive image; 0/1 select top/bottom bob.
        let field: Int?
        let offset: CMTime
        let duration: CMTime
    }
    let samples: [Sample]
    let outputFrameRate: Double

    init(frame: OMTVideoFrame, fieldOrder: ReceiverFieldOrder) throws {
        guard OMTFrameRate.isValid(numerator: frame.frameRateN, denominator: frame.frameRateD, maximum: 60) else {
            throw PlaybackFailure.unsupportedVideo
        }
        let interlaced = frame.flags & 1 != 0
        let doubleFields = interlaced && Int64(frame.frameRateN) <= Int64(frame.frameRateD) * 30
        let count = doubleFields ? 2 : 1
        let duration = Self.duration(numerator: frame.frameRateN, denominator: frame.frameRateD, count: count)
        outputFrameRate = Double(frame.frameRateN) / Double(frame.frameRateD) * Double(count)
        // Above 30 complete pairs/s, showing both fields would exceed our 60 Hz
        // budget. Keep the chosen first field at the original pair timestamp.
        samples = (0..<count).map { index in
            Sample(field: interlaced ? (fieldOrder.firstField + index) % 2 : nil,
                   // A zero with the duration's timescale could force CMTimeAdd
                   // to round even the original progressive/first-field PTS.
                   offset: index == 0 ? .zero : duration, duration: duration)
        }
    }

    private static func duration(numerator: Int, denominator: Int, count: Int) -> CMTime {
        // Validated Int32 terms and at most two fields fit safely in Int64.
        let scale = Int64(numerator) * Int64(count)
        var a = Int64(denominator), b = scale
        while b != 0 { (a, b) = (b, a % b) }
        let value = Int64(denominator) / a
        let reducedScale = scale / a
        if let exactScale = Int32(exactly: reducedScale) {
            return CMTime(value: value, timescale: exactScale)
        }
        // Only an irreducible two-field denominator can exceed CMTimeScale.
        // Round half away from zero at the largest representable timescale:
        // error <= 1/(2 * Int32.max) seconds (0.233 ns). The product plus
        // half the denominator fits Int64 for positive Int32 wire terms.
        let maximumScale = Int64(Int32.max)
        let roundedValue = (value * maximumScale + reducedScale / 2) / reducedScale
        return CMTime(value: roundedValue, timescale: Int32.max,
                      flags: [.valid, .hasBeenRounded], epoch: 0)
    }
}

/// A format transition retires queued native video and any pending second field,
/// without resetting audio or its shared clock. Includes alpha and pixel aspect.
struct ReceiverVideoFormat: Equatable {
    let width: Int
    let height: Int
    let numerator: Int
    let denominator: Int
    let flags: UInt32
    let colorSpace: Int
    let aspect: UInt32

    init(_ frame: OMTVideoFrame) {
        width = frame.width; height = frame.height
        numerator = frame.frameRateN; denominator = frame.frameRateD
        flags = frame.flags; colorSpace = frame.colorSpace; aspect = frame.aspectRatio.bitPattern
    }
}

/// AVFoundation requires increasing PTS within one renderer stream. Replacing a
/// duplicate or overlapping source picture starts a fresh video queue, while the
/// common audio clock continues unchanged. Source restart uses the same reset.
struct ReceiverVideoPresentationOrder {
    private(set) var last: CMTime?

    mutating func register(_ time: CMTime) -> Bool {
        let needsFlush = last.map { CMTimeCompare(time, $0) <= 0 } ?? false
        last = time
        return needsFlush
    }

    mutating func reset() { last = nil }

    static func fieldFits(sourceTimestamp: Int64, offset: CMTime, nextTimestamp: Int64?) -> Bool {
        guard let nextTimestamp else { return true }
        let source = CMTime(value: sourceTimestamp, timescale: 10_000_000)
        let next = CMTime(value: nextTimestamp, timescale: 10_000_000)
        // Compare the relative gap at the wire's exact 100 ns scale. Adding a
        // field to a large absolute PTS can otherwise force scale reduction.
        return CMTimeCompare(offset, CMTimeSubtract(next, source)) < 0
    }
}

/// Account at the enqueue boundary, before a pending field can be cancelled.
/// The first output records its source once; later fields add only output count.
/// Discarding this per-batch state must never discard already-recorded delivery.
struct ReceiverVideoSampleAccounting {
    private(set) var samplesAdmitted = 0

    mutating func record(firstSample: () -> Void, additionalSample: () -> Void) {
        if samplesAdmitted == 0 { firstSample() } else { additionalSample() }
        samplesAdmitted += 1
    }
}
