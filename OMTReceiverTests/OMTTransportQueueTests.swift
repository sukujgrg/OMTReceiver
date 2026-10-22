import XCTest
import Network
@testable import OMTReceiver

final class OMTTransportQueueTests: XCTestCase {
    func testSlowConsumerRetainsNewestVideoAndDoesNotDropAcceptedAudio() {
        let entered = expectation(description: "Callback entered")
        let latest = expectation(description: "Newest video delivered")
        let allAudio = expectation(description: "All accepted audio delivered")
        let gate = DispatchSemaphore(value: 0)
        let observations = PacketObservations()
        let mailbox = OMTPacketMailbox { packet in
            if case .metadata("gate") = packet {
                entered.fulfill()
                _ = gate.wait(timeout: .now() + 5)
            }
            if case .video(let frame) = packet {
                observations.appendVideo(frame.timestamp)
                if frame.timestamp == 200 { latest.fulfill() }
            }
            if case .audio = packet {
                if observations.addAudio() == 32 { allAudio.fulfill() }
            }
        }
        defer { gate.signal(); mailbox.close() }
        XCTAssertTrue(mailbox.offer(.metadata("gate")))
        wait(for: [entered], timeout: 2)
        for timestamp in 1...200 { XCTAssertTrue(mailbox.offer(.video(video(timestamp: Int64(timestamp))))) }
        for _ in 0..<32 { XCTAssertTrue(mailbox.offer(.audio(audio))) }
        XCTAssertFalse(mailbox.offer(.audio(audio)), "Backlog must fail explicitly rather than grow or drop audio")
        gate.signal()
        wait(for: [latest, allAudio], timeout: 2)
        XCTAssertEqual(observations.videos, [200])
        XCTAssertEqual(observations.audioCount, 32)
    }

    func testStopClearsQueuedPacketsWithoutWaitingForAdmittedCallback() {
        let entered = expectation(description: "Admitted callback")
        let returned = expectation(description: "Admitted callback finished")
        let queued = expectation(description: "Queued packet must not escape stop")
        queued.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        let mailbox = OMTPacketMailbox { packet in
            if case .metadata("gate") = packet {
                entered.fulfill()
                _ = gate.wait(timeout: .now() + 5)
                returned.fulfill()
            } else {
                queued.fulfill()
            }
        }
        defer { gate.signal(); mailbox.close() }
        XCTAssertTrue(mailbox.offer(.metadata("gate")))
        wait(for: [entered], timeout: 2)
        XCTAssertTrue(mailbox.offer(.video(video(timestamp: 10))))
        XCTAssertTrue(mailbox.offer(.audio(audio)))
        XCTAssertTrue(mailbox.close())
        XCTAssertFalse(mailbox.close(), "Closing is idempotent")
        XCTAssertFalse(mailbox.offer(.metadata("stale")))
        gate.signal()
        wait(for: [returned], timeout: 2)
        wait(for: [queued], timeout: 0.1)
    }

    func testStopBeforeStartCannotCreateConnectionOrDeliverState() {
        let state = expectation(description: "No callback after stop-before-start")
        state.isInverted = true
        let connection = OMTConnection(endpoint: .hostPort(host: "127.0.0.1", port: 9), onPacket: { _ in
            state.fulfill()
        }, onState: { _ in state.fulfill() })
        connection.stop()
        connection.start()
        wait(for: [state], timeout: 0.1)
    }

    private func video(timestamp: Int64) -> OMTVideoFrame {
        .init(timestamp: timestamp, codec: OMTCodec.vmx1, width: 16, height: 16, frameRateN: 30, frameRateD: 1,
              aspectRatio: 1, flags: 0, colorSpace: 709, payload: Data([1]))
    }

    private var audio: OMTAudioFrame {
        .init(timestamp: 0, codec: OMTCodec.fpa1, sampleRate: 48_000, samplesPerChannel: 960,
              channels: 2, activeChannels: 0, payload: Data())
    }
}

private final class PacketObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var videoValues: [Int64] = []
    private var audioValue = 0
    var videos: [Int64] { lock.withLock { videoValues } }
    var audioCount: Int { lock.withLock { audioValue } }
    func appendVideo(_ timestamp: Int64) { lock.withLock { videoValues.append(timestamp) } }
    func addAudio() -> Int { lock.withLock { audioValue += 1; return audioValue } }
}
