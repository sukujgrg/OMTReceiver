import Foundation

/// Retain compressed future pictures until native rendering is near their PTS.
/// The queue is confined by its owner's lock; no decoder surfaces are held here.
struct ReceiverVideoQueue {
    struct Entry {
        let id: UInt64
        let frame: OMTVideoFrame
    }
    private var frames: [Entry] = []
    private var nextID: UInt64 = 0
    private(set) var byteCount = 0
    let maximumDuration: Double
    let maximumFrames: Int
    let maximumBytes: Int

    init(playoutDelay: Double, maximumBytes: Int = 16 * 1024 * 1024) {
        // One route budget plus the existing 120 ms network/decode headroom.
        // Two seconds is a hard resource ceiling, not extra presentation delay.
        maximumDuration = min(2, max(0.300, playoutDelay + ReceiverTimeline.delay))
        maximumFrames = Int(ceil(maximumDuration * 60)) + 2
        self.maximumBytes = maximumBytes
    }

    var first: Entry? { frames.first }
    var isEmpty: Bool { frames.isEmpty }
    var count: Int { frames.count }

    /// Preserve the 30 fps native preroll as a time budget. At 60 fps
    /// this retains eight future pictures, plus the displayed and active decode
    /// surfaces within VMXFrameDecoder's ten-surface allocation ceiling.
    /// This only advances decoding; presentation timestamps stay unchanged.
    static func decodeLead(playoutDelay: Double) -> Double {
        min(playoutDelay, Double(VMXFrameDecoder.maximumRetainedFrames - 2) / 60)
    }

    @discardableResult
    mutating func append(_ frame: OMTVideoFrame) -> Int {
        var skipped = 0
        if let last = frames.last {
            if frame.timestamp < last.frame.timestamp {
                skipped = frames.count
                removeAll()
            } else if frame.timestamp == last.frame.timestamp {
                byteCount -= frames.removeLast().frame.payload.count
                skipped += 1
            }
        }
        nextID &+= 1
        frames.append(Entry(id: nextID, frame: frame))
        byteCount += frame.payload.count
        while let first = frames.first, let last = frames.last,
              frames.count > maximumFrames || byteCount > maximumBytes
                || (Double(last.frame.timestamp) - Double(first.frame.timestamp)) / 10_000_000 > maximumDuration {
            byteCount -= frames.removeFirst().frame.payload.count
            skipped += 1
        }
        return skipped
    }

    /// A replacement, overflow or reset can invalidate a peek while decoding.
    /// Never consume a different picture or submit an obsolete decoded result.
    mutating func consumeFirst(matching id: UInt64) -> Bool {
        guard frames.first?.id == id else { return false }
        byteCount -= frames.removeFirst().frame.payload.count
        return true
    }

    mutating func removeAll() {
        frames.removeAll()
        byteCount = 0
    }
}
