import Foundation
import XCTest
@testable import OMTReceiver

final class ReceiverVideoQueueTests: XCTestCase {
    private func frame(_ timestamp: Int64, bytes: Int = 1, fps: Int = 60) -> OMTVideoFrame {
        .init(timestamp: timestamp, codec: OMTCodec.vmx1, width: 1920, height: 1080,
              frameRateN: fps, frameRateD: 1, aspectRatio: 16 / 9, flags: 0,
              colorSpace: 709, payload: Data(repeating: 1, count: bytes))
    }

    func testHDMIBudgetRetainsEveryCompressedSixtyFPSPictureInOrder() throws {
        var queue = ReceiverVideoQueue(playoutDelay: 0.120 + 0.080 + 1024.0 / 48000)
        // Fourteen arrivals span the HDMI scheduling lead at 60 fps. A latest-
        // picture mailbox loses thirteen pictures before native rendering frees.
        let timestamps = (0..<14).map { Int64($0) * 10_000_000 / 60 }
        for t in timestamps { XCTAssertEqual(queue.append(frame(t)), 0) }
        var actual: [Int64] = []
        while let entry = queue.first {
            actual.append(entry.frame.timestamp)
            XCTAssertTrue(queue.consumeFirst(matching: entry.id))
        }
        XCTAssertEqual(actual, timestamps)
        XCTAssertEqual(queue.byteCount, 0)
    }

    func testFrameByteAndTimestampBoundsEachDiscardOldestPictures() throws {
        var countBound = ReceiverVideoQueue(playoutDelay: 0.221)
        for t in 0..<200 { countBound.append(frame(Int64(t))) }
        XCTAssertEqual(countBound.count, countBound.maximumFrames)
        XCTAssertEqual(countBound.byteCount, countBound.count)
        var byteBound = ReceiverVideoQueue(playoutDelay: 0.221, maximumBytes: 10)
        byteBound.append(frame(0, bytes: 6)); byteBound.append(frame(1, bytes: 6))
        XCTAssertEqual(byteBound.count, 1)
        XCTAssertEqual(byteBound.byteCount, 6)
        XCTAssertEqual(byteBound.first?.frame.timestamp, 1)
        var timeBound = ReceiverVideoQueue(playoutDelay: 0.221)
        timeBound.append(frame(0))
        XCTAssertEqual(timeBound.append(frame(10_000_000)), 1)
        XCTAssertEqual(timeBound.first?.frame.timestamp, 10_000_000)
    }

    func testReplacingAPeekedPictureCannotConsumeOrSubmitItsReplacement() throws {
        var queue = ReceiverVideoQueue(playoutDelay: 0.221)
        queue.append(frame(10))
        let old = try XCTUnwrap(queue.first)
        XCTAssertEqual(queue.append(frame(10, bytes: 2)), 1)
        XCTAssertFalse(queue.consumeFirst(matching: old.id))
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.byteCount, 2)
        XCTAssertTrue(queue.consumeFirst(matching: try XCTUnwrap(queue.first).id))
    }

    func testRestartAndResetInvalidateOldPeekWithoutDiscardingNewSource() throws {
        var queue = ReceiverVideoQueue(playoutDelay: 0.221)
        queue.append(frame(100)); queue.append(frame(200))
        let old = try XCTUnwrap(queue.first)
        XCTAssertEqual(queue.append(frame(0)), 2)
        XCTAssertFalse(queue.consumeFirst(matching: old.id))
        XCTAssertEqual(queue.first?.frame.timestamp, 0)
        let beforeReset = try XCTUnwrap(queue.first)
        queue.removeAll(); queue.append(frame(0))
        XCTAssertFalse(queue.consumeFirst(matching: beforeReset.id))
        XCTAssertEqual(queue.count, 1)
    }

    func testOverflowWhileDecodingInvalidatesOnlyTheObsoletePeek() throws {
        var queue = ReceiverVideoQueue(playoutDelay: 0.221, maximumBytes: 8)
        queue.append(frame(0, bytes: 8))
        let active = try XCTUnwrap(queue.first)
        queue.append(frame(1, bytes: 8))
        XCTAssertFalse(queue.consumeFirst(matching: active.id))
        XCTAssertEqual(queue.first?.frame.timestamp, 1)
        XCTAssertEqual(queue.byteCount, 8)
    }

    func testDecodePrerollPreservesTimeBudgetWithinTheSurfaceCeiling() {
        let lead = ReceiverVideoQueue.decodeLead(playoutDelay: 0.221)
        XCTAssertEqual(lead, 4.0 / 30, accuracy: 0.000001)
        XCTAssertEqual(ReceiverVideoQueue.decodeLead(playoutDelay: 0.8), lead)
        XCTAssertEqual(ReceiverVideoQueue.decodeLead(playoutDelay: 0.100), 0.100)
        for fps in [30.0, 50.0, 60000.0 / 1001, 60.0] {
            // Future pictures plus current display and active decode must fit.
            XCTAssertLessThanOrEqual(Int(ceil(lead * fps)) + 2, VMXFrameDecoder.maximumRetainedFrames)
        }
        let longer = ReceiverVideoQueue(playoutDelay: 0.8)
        XCTAssertGreaterThan(longer.maximumDuration, 0.8)
    }
}
