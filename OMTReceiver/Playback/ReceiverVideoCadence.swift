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
        guard (1...1_000_000).contains(frame.frameRateN), (1...100_000).contains(frame.frameRateD),
              Double(frame.frameRateN) / Double(frame.frameRateD) <= 60 else {
            throw PlaybackFailure.unsupportedVideo
        }
        let interlaced = frame.flags & 1 != 0
        let doubleFields = interlaced && Int64(frame.frameRateN) <= Int64(frame.frameRateD) * 30
        let count = doubleFields ? 2 : 1
        let duration = CMTime(value: Int64(frame.frameRateD), timescale: Int32(frame.frameRateN * count))
        outputFrameRate = Double(frame.frameRateN) / Double(frame.frameRateD) * Double(count)
        // Above 30 complete pairs/s, showing both fields would exceed our 60 Hz
        // budget. Keep the chosen first field at the original pair timestamp.
        samples = (0..<count).map { index in
            Sample(field: interlaced ? (fieldOrder.firstField + index) % 2 : nil,
                   offset: CMTimeMultiply(duration, multiplier: Int32(index)), duration: duration)
        }
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
        return CMTimeCompare(CMTimeAdd(source, offset), next) < 0
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
