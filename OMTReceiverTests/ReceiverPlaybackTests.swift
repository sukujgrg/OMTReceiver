import CoreMedia
import XCTest
@testable import OMTReceiver

final class ReceiverPlaybackTests: XCTestCase {
    func testSenderVideoAndAudioUseOneMappingWithBoundedLead() throws {
        var clock = ReceiverTimeline()
        let video = try clock.map(900_000_000, lane: .video, hostNow: 4)
        let audio = try clock.map(900_200_000, lane: .audio, hostNow: 4.001)
        XCTAssertTrue(video.globalReset)
        XCTAssertFalse(audio.globalReset)
        XCTAssertFalse(audio.laneReset)
        XCTAssertEqual(video.presentationTime.seconds, 0.120, accuracy: 0.000_001)
        XCTAssertEqual(audio.presentationTime.seconds - video.presentationTime.seconds, 0.020, accuracy: 0.000_001)
        XCTAssertEqual(video.hostAnchor, audio.hostAnchor)
    }

    func testHDMIRouteLatencyPreservesRenderDeadlineAndCommonAVMapping() throws {
        let outputLatency = 0.080, ioDuration = 1024.0 / 48000
        var clock = ReceiverTimeline(audioOutputLatency: outputLatency, ioBufferDuration: ioDuration)
        let first = try clock.map(0, lane: .audio, hostNow: 100)
        // Controlled reproduction: 107 ms of arrival jitter measured on A10X.
        let delayed = try clock.map(200_000, lane: .audio, hostNow: 100.127)
        let hardwareDeadlineLead = outputLatency + ioDuration
        XCTAssertGreaterThan(delayed.presentationTime.seconds - 0.127, hardwareDeadlineLead)
        XCTAssertFalse(delayed.laneReset)
        let video = try clock.map(200_000, lane: .video, hostNow: 100.127)
        XCTAssertEqual(video.presentationTime.seconds, delayed.presentationTime.seconds, accuracy: 0.000_001)
        XCTAssertEqual(first.hostAnchor, video.hostAnchor)
        XCTAssertEqual(first.presentationTime.seconds, 0.120 + hardwareDeadlineLead, accuracy: 0.000_001)
    }

    func testLongerAudioRouteLeadDoesNotCauseRepeatedFalseDiscontinuities() throws {
        var clock = ReceiverTimeline(audioOutputLatency: 0.800, ioBufferDuration: 0.020)
        _ = try clock.map(0, lane: .audio, hostNow: 10)
        for index in 1...100 {
            let next = try clock.map(Int64(index) * 200_000, lane: .audio, hostNow: 10 + Double(index) * 0.020)
            XCTAssertFalse(next.globalReset || next.laneReset)
            XCTAssertEqual(next.presentationTime.seconds, Double(index) * 0.020 + 0.940, accuracy: 0.000_001)
        }
    }

    func testIndependentLaneRecoveryRetainsTheAudioRouteBudget() throws {
        var clock = ReceiverTimeline(audioOutputLatency: 0.080, ioBufferDuration: 0.020)
        _ = try clock.map(100_000_000, lane: .video, hostNow: 10)
        let audio = try clock.map(0, lane: .audio, hostNow: 10.020)
        XCTAssertTrue(audio.laneReset)
        XCTAssertEqual(audio.presentationTime.seconds, 0.240, accuracy: 0.000_001)
        let video = try clock.map(100_200_000, lane: .video, hostNow: 10.020)
        XCTAssertFalse(video.laneReset)
        XCTAssertEqual(video.presentationTime.seconds, audio.presentationTime.seconds, accuracy: 0.000_001)
    }

    func testBackwardDiscontinuityKeepsGlobalClockAndReconnectResetsIt() throws {
        var clock = ReceiverTimeline()
        _ = try clock.map(100_000_000, lane: .video, hostNow: 20)
        XCTAssertFalse(try clock.map(110_000_000, lane: .video, hostNow: 21).laneReset)
        let restarted = try clock.map(0, lane: .video, hostNow: 21.010)
        XCTAssertFalse(restarted.globalReset)
        XCTAssertTrue(restarted.laneReset)
        XCTAssertEqual(restarted.presentationTime.seconds, 1.130, accuracy: 0.000_001)
        clock.reset()
        XCTAssertTrue(try clock.map(Int64.max, lane: .video, hostNow: 100).globalReset)
        XCTAssertThrowsError(try clock.map(-1, lane: .audio, hostNow: 101))
    }

    func testLargeFutureJumpCannotAccumulateUnboundedPlaybackLatency() throws {
        var clock = ReceiverTimeline()
        _ = try clock.map(0, lane: .video, hostNow: 1)
        let next = try clock.map(1_000_000_000, lane: .video, hostNow: 1.01)
        XCTAssertFalse(next.globalReset)
        XCTAssertTrue(next.laneReset)
        XCTAssertEqual(next.presentationTime.seconds, 0.010 + ReceiverTimeline.delay, accuracy: 0.000_001)
    }

    func testLateIndependentAudioOriginDoesNotFlushHealthyVideo() throws {
        var clock = ReceiverTimeline()
        _ = try clock.map(0, lane: .video, hostNow: 100)
        _ = try clock.map(100_000_000, lane: .video, hostNow: 110)
        let audio = try clock.map(0, lane: .audio, hostNow: 110)
        XCTAssertFalse(audio.globalReset)
        XCTAssertTrue(audio.laneReset)
        XCTAssertEqual(audio.presentationTime.seconds, 10.120, accuracy: 0.000_001)
        for index in 1...500 {
            let host = 110 + Double(index) * 0.020
            let video = try clock.map(100_000_000 + Int64(index) * 200_000, lane: .video, hostNow: host)
            let audio = try clock.map(Int64(index) * 200_000, lane: .audio, hostNow: host)
            XCTAssertFalse(video.globalReset || video.laneReset)
            XCTAssertFalse(audio.globalReset || audio.laneReset)
            XCTAssertEqual(video.presentationTime.seconds, audio.presentationTime.seconds, accuracy: 0.000_001)
        }
    }

    func testOneSidedRestartDoesNotResetCompanionLane() throws {
        var clock = ReceiverTimeline()
        _ = try clock.map(0, lane: .video, hostNow: 100)
        _ = try clock.map(0, lane: .audio, hostNow: 100)
        _ = try clock.map(100_000_000, lane: .video, hostNow: 110)
        _ = try clock.map(100_000_000, lane: .audio, hostNow: 110)
        let videoRestart = try clock.map(0, lane: .video, hostNow: 110.020)
        XCTAssertTrue(videoRestart.laneReset)
        XCTAssertFalse(videoRestart.globalReset)
        let audio = try clock.map(100_200_000, lane: .audio, hostNow: 110.020)
        XCTAssertFalse(audio.globalReset || audio.laneReset)
        let audioRestart = try clock.map(0, lane: .audio, hostNow: 110.040)
        XCTAssertTrue(audioRestart.laneReset)
        let video = try clock.map(200_000, lane: .video, hostNow: 110.040)
        XCTAssertFalse(video.globalReset || video.laneReset)
    }

    func testSparseAudioExpandsInactiveChannelsAndPreservesSamples() throws {
        let frame = audio(values: [0.25, -0.25], channels: 2, active: 2, count: 2)
        XCTAssertEqual(try FPA1AudioDecoder.samples(frame), [0, 0.25, 0, -0.25])
        let silence = audio(values: [], channels: 2, active: 0, count: 960)
        XCTAssertEqual(try FPA1AudioDecoder.samples(silence), [Float](repeating: 0, count: 1920))
    }

    func testSparseAudioValidatesUnmonitoredChannelsAndWireLength() {
        XCTAssertThrowsError(try FPA1AudioDecoder.samples(audio(values: [.nan], channels: 3, active: 4, count: 1)))
        XCTAssertThrowsError(try FPA1AudioDecoder.samples(audio(values: [0], channels: 2, active: 4, count: 1)))
        XCTAssertThrowsError(try FPA1AudioDecoder.samples(audio(values: [0], channels: 2, active: 3, count: 1)))
    }

    func testAudioSampleCarriesSenderPresentationTimeAndExactDuration() throws {
        let frame = audio(values: [], channels: 2, active: 0, count: 960)
        let sample = try FPA1AudioDecoder.makeSample(frame, at: CMTime(value: 120, timescale: 1000))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 960)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, 0.120, accuracy: 0.000_001)
        XCTAssertEqual(CMSampleBufferGetDuration(sample).seconds, 0.020, accuracy: 0.000_001)
    }

    private func audio(values: [Float], channels: Int, active: UInt32, count: Int) -> OMTAudioFrame {
        var bytes = Data()
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return .init(timestamp: 0, codec: OMTCodec.fpa1, sampleRate: 48000, samplesPerChannel: count,
                     channels: channels, activeChannels: active, payload: bytes)
    }
}
