import CoreMedia
import Foundation
import XCTest
@testable import OMTReceiver

final class ReceiverVideoCadenceTests: XCTestCase {
    private func frame(_ n: Int, _ d: Int = 1, interlaced: Bool = true, timestamp: Int64 = 0) -> OMTVideoFrame {
        .init(timestamp: timestamp, codec: OMTCodec.vmx1, width: 1920, height: 1080,
              frameRateN: n, frameRateD: d, aspectRatio: 16 / 9, flags: interlaced ? 1 : 0,
              colorSpace: 709, payload: Data([1]))
    }

    func testConventionalPairRatesPresentBothOrderedFieldsAtTheirNaturalTimes() throws {
        for (n, d) in [(25, 1), (30, 1), (30000, 1001), (24000, 1001)] {
            for order in ReceiverFieldOrder.allCases {
                let cadence = try ReceiverVideoCadence(frame: frame(n, d), fieldOrder: order)
                XCTAssertEqual(cadence.samples.map(\.field), [order.firstField, 1 - order.firstField])
                XCTAssertEqual(cadence.outputFrameRate, Double(n * 2) / Double(d), accuracy: 0.000_001)
                XCTAssertEqual(CMTimeCompare(cadence.samples[0].offset, .zero), 0)
                XCTAssertEqual(CMTimeCompare(cadence.samples[1].offset, CMTime(value: Int64(d), timescale: Int32(n * 2))), 0)
                XCTAssertEqual(CMTimeCompare(CMTimeMultiply(cadence.samples[0].duration, multiplier: 2),
                                             CMTime(value: Int64(d), timescale: Int32(n))), 0)
            }
        }
    }

    func testHighPairRatesStayWithinSixtyHzAndDoNotCreateOverlappingFields() throws {
        for (n, d) in [(50, 1), (60, 1), (60000, 1001), (31, 1)] {
            let cadence = try ReceiverVideoCadence(frame: frame(n, d), fieldOrder: .bottomFirst)
            XCTAssertEqual(cadence.samples.count, 1)
            XCTAssertEqual(cadence.samples[0].field, 1)
            XCTAssertEqual(CMTimeCompare(cadence.samples[0].offset, .zero), 0)
            XCTAssertLessThanOrEqual(cadence.outputFrameRate, 60)
            XCTAssertEqual(CMTimeCompare(cadence.samples[0].duration, CMTime(value: Int64(d), timescale: Int32(n))), 0)
        }
    }

    func testProgressiveRatesAndPresentationTimestampsRemainUnchanged() throws {
        for (n, d) in [(25, 1), (30, 1), (50, 1), (60, 1), (60000, 1001)] {
            let cadence = try ReceiverVideoCadence(frame: frame(n, d, interlaced: false), fieldOrder: .bottomFirst)
            XCTAssertEqual(cadence.samples.count, 1)
            XCTAssertNil(cadence.samples[0].field)
            XCTAssertEqual(CMTimeCompare(cadence.samples[0].offset, .zero), 0)
            XCTAssertEqual(cadence.outputFrameRate, Double(n) / Double(d), accuracy: 0.000_001)
        }
        for invalid in [frame(0), frame(30, 0), frame(Int.max), frame(60, Int.max), frame(61)] {
            XCTAssertThrowsError(try ReceiverVideoCadence(frame: invalid, fieldOrder: .topFirst))
        }
    }

    func testFractionalFieldTimestampsStayOrderedAndShareTheUnmodifiedAudioClock() throws {
        var timeline = ReceiverTimeline()
        var order = ReceiverVideoPresentationOrder()
        let cadence = try ReceiverVideoCadence(frame: frame(30000, 1001), fieldOrder: .topFirst)
        for index in 0..<3000 {
            let timestamp = Int64(index) * 10_000_000 * 1001 / 30000
            let now = 100 + Double(timestamp) / 10_000_000
            let video = try timeline.map(timestamp, lane: .video, hostNow: now)
            let audio = try timeline.map(timestamp, lane: .audio, hostNow: now)
            XCTAssertFalse(video.laneReset || audio.laneReset)
            XCTAssertEqual(CMTimeCompare(video.presentationTime, audio.presentationTime), 0)
            for sample in cadence.samples {
                XCTAssertFalse(order.register(CMTimeAdd(video.presentationTime, sample.offset)))
            }
            let next = Int64(index + 1) * 10_000_000 * 1001 / 30000
            XCTAssertTrue(ReceiverVideoPresentationOrder.fieldFits(sourceTimestamp: timestamp,
                offset: cadence.samples[1].offset, nextTimestamp: next))
        }
    }

    func testPendingFieldCannotOverlapNextPacketAndRestartResetsOnlyVideoOrdering() throws {
        let cadence = try ReceiverVideoCadence(frame: frame(30), fieldOrder: .topFirst)
        let half = cadence.samples[1].offset
        XCTAssertTrue(ReceiverVideoPresentationOrder.fieldFits(sourceTimestamp: 0, offset: half, nextTimestamp: 333_333))
        XCTAssertFalse(ReceiverVideoPresentationOrder.fieldFits(sourceTimestamp: 0, offset: half, nextTimestamp: 100_000))
        XCTAssertFalse(ReceiverVideoPresentationOrder.fieldFits(sourceTimestamp: 0, offset: half, nextTimestamp: 0))
        XCTAssertTrue(ReceiverVideoPresentationOrder.fieldFits(sourceTimestamp: 0, offset: half, nextTimestamp: nil))
        var order = ReceiverVideoPresentationOrder()
        XCTAssertFalse(order.register(.zero))
        XCTAssertFalse(order.register(half))
        XCTAssertTrue(order.register(half)) // Duplicate PTS requires a native video flush.
        XCTAssertTrue(order.register(.zero)) // A restarted sender cannot follow the old field.
        order.reset()
        XCTAssertFalse(order.register(.zero))
        XCTAssertNotEqual(ReceiverVideoFormat(frame(30)), ReceiverVideoFormat(frame(30, interlaced: false)))
    }

    func testFirstFieldAccountingSurvivesBackpressureCancellationAndNewBatch() {
        var batch = ReceiverVideoSampleAccounting()
        var sourceFrames = 0, outputSamples = 0
        func enqueue(ready: Bool) {
            guard ready else { return }
            batch.record(firstSample: { sourceFrames += 1; outputSamples += 1 },
                         additionalSample: { outputSamples += 1 })
        }
        enqueue(ready: true)
        // The source and first sample must be observable immediately, before
        // readiness allows its second field or the batch finishes.
        XCTAssertEqual(sourceFrames, 1); XCTAssertEqual(outputSamples, 1)
        enqueue(ready: false)
        XCTAssertEqual(batch.samplesAdmitted, 1)
        XCTAssertEqual(sourceFrames, 1); XCTAssertEqual(outputSamples, 1)
        // Reset/discontinuity drops pending batch state, not admitted counters.
        batch = ReceiverVideoSampleAccounting()
        XCTAssertEqual(sourceFrames, 1); XCTAssertEqual(outputSamples, 1)
        enqueue(ready: true)
        XCTAssertEqual(sourceFrames, 2); XCTAssertEqual(outputSamples, 2)
        enqueue(ready: true)
        XCTAssertEqual(sourceFrames, 2); XCTAssertEqual(outputSamples, 3)
    }

    func testBothFieldOutputPreservesNativePreparationInsideTenSurfaces() {
        let lead = ReceiverVideoQueue.decodeLead(playoutDelay: 0.221)
        XCTAssertEqual(lead, 4.0 / 30, accuracy: 0.000_001)
        XCTAssertEqual(ReceiverVideoQueue.decodeLead(playoutDelay: 0.080), 0.080)
        for sourceFPS in [24.0, 25.0, 30000.0 / 1001, 30.0] {
            let outputFPS = sourceFPS * 2
            // Before decoding a pair, older native future samples end one field
            // before this pair's first PTS. The displayed image plus both new
            // outputs must fit; the woven image becomes an output in-place.
            let previousFuture = Int(ceil((lead - 1 / outputFPS) * outputFPS - 0.000_001))
            XCTAssertLessThanOrEqual(previousFuture + 1 + 2, VMXFrameDecoder.maximumRetainedFrames)
        }
    }
}
