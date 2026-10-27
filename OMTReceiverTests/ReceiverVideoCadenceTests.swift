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

    func testLargeProgressiveRateTermsPreserveExactRateDurationAndSourcePTS() throws {
        let rates = [(3_000_003, 100_000), (3_000_030, 100_001),
                     (Int(Int32.max), Int(Int32.max)), (1, Int(Int32.max)),
                     (2_147_483_640, 35_791_394)]
        for (n, d) in rates {
            for timestamp in [Int64(788_000_123), Int64.max - 1] {
                let source = frame(n, d, interlaced: false, timestamp: timestamp)
                let format = ReceiverVideoFormat(source)
                let cadence = try ReceiverVideoCadence(frame: source, fieldOrder: .bottomFirst)
                let sample = try XCTUnwrap(cadence.samples.first)
                XCTAssertEqual(cadence.samples.count, 1)
                XCTAssertNil(sample.field)
                XCTAssertEqual(cadence.outputFrameRate, Double(n) / Double(d))
                XCTAssertEqual(CMTimeCompare(sample.duration, CMTime(value: Int64(d), timescale: Int32(n))), 0)
                XCTAssertFalse(sample.duration.hasBeenRounded)
                let original = CMTime(value: timestamp, timescale: 10_000_000)
                let presented = CMTimeAdd(original, sample.offset)
                XCTAssertEqual(presented.value, original.value)
                XCTAssertEqual(presented.timescale, original.timescale)
                XCTAssertFalse(presented.hasBeenRounded)
                XCTAssertEqual(source.timestamp, timestamp)
                XCTAssertEqual(source.frameRateN, n); XCTAssertEqual(source.frameRateD, d)
                XCTAssertEqual(format.numerator, n); XCTAssertEqual(format.denominator, d)
            }
        }
    }

    func testInvalidDirectRateTermsAndExactSixtyFPSBoundary() throws {
        for (n, d) in [(0, 1), (-1, 1), (30, 0), (30, -1),
                       (Int(Int32.max) + 1, Int(Int32.max)), (30, Int(Int32.max) + 1),
                       (Int.max, Int.max), (Int.min, 1), (1, Int.min),
                       (61, 1), (60_001, 1_000), (2_147_483_641, 35_791_394)] {
            XCTAssertThrowsError(try ReceiverVideoCadence(frame: frame(n, d), fieldOrder: .topFirst), "\(n)/\(d)")
        }
        let boundary = try ReceiverVideoCadence(frame: frame(2_147_483_640, 35_791_394), fieldOrder: .topFirst)
        XCTAssertEqual(boundary.outputFrameRate, 60)
        XCTAssertEqual(boundary.samples.count, 1)
    }

    func testLargeInterlacedTermsReduceExactlyBeforeConstructingCMTime() throws {
        // Each unreduced doubled numerator is larger than Int32.max. All of
        // these field durations nevertheless have an exact CMTime rational.
        for (n, d) in [(1_800_000_000, 60_000_000), (2_147_483_646, 100_000_000),
                       (Int(Int32.max), Int(Int32.max))] {
            for order in ReceiverFieldOrder.allCases {
                let source = frame(n, d, timestamp: 788_000_123)
                let cadence = try ReceiverVideoCadence(frame: source, fieldOrder: order)
                XCTAssertEqual(cadence.samples.map(\.field), [order.firstField, 1 - order.firstField])
                XCTAssertLessThanOrEqual(cadence.outputFrameRate, 60)
                XCTAssertEqual(CMTimeCompare(cadence.samples[0].offset, .zero), 0)
                let duration = cadence.samples[0].duration
                XCTAssertTrue(duration.isNumeric)
                XCTAssertGreaterThan(duration.timescale, 0)
                XCTAssertFalse(duration.hasBeenRounded)
                XCTAssertEqual(CMTimeCompare(duration, cadence.samples[1].offset), 0)
                XCTAssertEqual(CMTimeCompare(duration, cadence.samples[1].duration), 0)
                XCTAssertEqual(CMTimeCompare(CMTimeMultiply(duration, multiplier: 2),
                                             CMTime(value: Int64(d), timescale: Int32(n))), 0)
                let pts = CMTime(value: source.timestamp, timescale: 10_000_000)
                XCTAssertEqual(CMTimeAdd(pts, cadence.samples[0].offset).value, pts.value)
                XCTAssertEqual(source.frameRateN, n); XCTAssertEqual(source.frameRateD, d)
                XCTAssertEqual(source.timestamp, 788_000_123)
            }
        }
    }

    func testUnrepresentableInterlacedFractionRoundsWithinHalfACMTimeTick() throws {
        let d: Int64 = 100_000_001
        // Include a half-tie and non-tie residues at the maximum timescale.
        for n in [Int64(Int32.max), Int64(Int32.max) - 2] {
            for order in ReceiverFieldOrder.allCases {
                let source = frame(Int(n), Int(d), timestamp: 788_000_123)
                let cadence = try ReceiverVideoCadence(frame: source, fieldOrder: order)
                XCTAssertEqual(cadence.samples.map(\.field), [order.firstField, 1 - order.firstField])
                XCTAssertLessThanOrEqual(cadence.outputFrameRate, 60)
                let duration = cadence.samples[0].duration
                XCTAssertTrue(duration.isNumeric)
                XCTAssertTrue(duration.hasBeenRounded)
                XCTAssertEqual(duration.timescale, Int32.max)
                // Exact integer error in ticks: abs(value - d*scale/(2*n)).
                // These cross products fit Int64, avoiding a Double tolerance
                // that could hide a rounding error at a large absolute PTS.
                let residual = abs(duration.value * (2 * n) - d * Int64(duration.timescale))
                XCTAssertLessThanOrEqual(residual * 2, 2 * n)
                XCTAssertEqual(CMTimeCompare(cadence.samples[1].offset, duration), 0)
                XCTAssertEqual(CMTimeCompare(cadence.samples[1].duration, duration), 0)
                let firstPTS = CMTime(value: source.timestamp, timescale: 10_000_000)
                XCTAssertEqual(CMTimeAdd(firstPTS, cadence.samples[0].offset).value, firstPTS.value)
                let secondPTS = CMTimeAdd(firstPTS, cadence.samples[1].offset)
                XCTAssertTrue(secondPTS.isNumeric)
                // Composition can round once more when its LCM exceeds Int32.
                let expected = firstPTS.seconds + Double(d) / Double(2 * n)
                XCTAssertEqual(secondPTS.seconds, expected, accuracy: 1 / Double(Int32.max))
                XCTAssertEqual(source.frameRateN, Int(n)); XCTAssertEqual(source.frameRateD, Int(d))
                XCTAssertEqual(source.timestamp, 788_000_123)
            }
        }
    }

    func testInterlacedBudgetUsesExactRatioAndFormatKeepsOriginalTerms() throws {
        for (n, d, count) in [(3_000_003, 100_000, 1), (3_000_000, 100_000, 2),
                              (2_147_483_640, 71_582_788, 2), (2_147_483_641, 71_582_788, 1)] {
            let source = frame(n, d)
            let cadence = try ReceiverVideoCadence(frame: source, fieldOrder: .bottomFirst)
            XCTAssertEqual(cadence.samples.count, count)
            XCTAssertEqual(cadence.samples.first?.field, 1)
            XCTAssertLessThanOrEqual(cadence.outputFrameRate, 60)
            XCTAssertEqual(source.frameRateN, n); XCTAssertEqual(source.frameRateD, d)
        }
        // Format identity intentionally includes the sender's original terms.
        XCTAssertNotEqual(ReceiverVideoFormat(frame(3_000_000, 100_000)), ReceiverVideoFormat(frame(30)))
    }

    func testPendingLargeRateFieldUsesExactWireGapAtLargeSourceTimestamps() throws {
        let cadence = try ReceiverVideoCadence(frame: frame(Int(Int32.max), 100_000_001), fieldOrder: .topFirst)
        let half = cadence.samples[1].offset
        let gapBelow = Int64(100_000_001) * 10_000_000 / (2 * Int64(Int32.max))
        for source in [Int64(0), Int64.max - 1_000_000] {
            XCTAssertFalse(ReceiverVideoPresentationOrder.fieldFits(sourceTimestamp: source,
                offset: half, nextTimestamp: source + gapBelow))
            XCTAssertTrue(ReceiverVideoPresentationOrder.fieldFits(sourceTimestamp: source,
                offset: half, nextTimestamp: source + gapBelow + 1))
        }
    }

    func testFractionalFieldTimestampsStayOrderedAndShareTheUnmodifiedAudioClock() throws {
        for (n, d): (Int64, Int64) in [(30_000, 1_001), (Int64(Int32.max), 100_000_001)] {
            var timeline = ReceiverTimeline()
            var order = ReceiverVideoPresentationOrder()
            let cadence = try ReceiverVideoCadence(frame: frame(Int(n), Int(d)), fieldOrder: .topFirst)
            for index in 0..<3000 {
                let timestamp = Int64(index) * 10_000_000 * d / n
                let now = 100 + Double(timestamp) / 10_000_000
                let video = try timeline.map(timestamp, lane: .video, hostNow: now)
                let audio = try timeline.map(timestamp, lane: .audio, hostNow: now)
                XCTAssertFalse(video.laneReset || audio.laneReset)
                XCTAssertEqual(CMTimeCompare(video.presentationTime, audio.presentationTime), 0)
                for sample in cadence.samples {
                    XCTAssertFalse(order.register(CMTimeAdd(video.presentationTime, sample.offset)))
                }
                let next = Int64(index + 1) * 10_000_000 * d / n
                XCTAssertTrue(ReceiverVideoPresentationOrder.fieldFits(sourceTimestamp: timestamp,
                    offset: cadence.samples[1].offset, nextTimestamp: next))
            }
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
