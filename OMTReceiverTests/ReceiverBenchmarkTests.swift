import Foundation
import XCTest
@testable import OMTReceiver

final class ReceiverBenchmarkTests: XCTestCase {
    func testAudioTraceSeparatesTransportBurstFromLocalQueueWaits() throws {
        var trace = BenchmarkAudioTrace()
        trace.received(100_000, at: 1)
        trace.delivered(100_000, at: 1.001)
        trace.queued(100_000, at: 1.002)
        trace.admitted(100_000, at: 1.003, lead: 0.22, horizon: 0.101333,
                       sampleBuildMs: 0.1, rendererEnqueueMs: 0.05)
        trace.received(300_000, at: 1.130)
        trace.delivered(300_000, at: 1.131)
        trace.queued(300_000, at: 1.132)
        trace.admitted(300_000, at: 1.133, lead: 0.09, horizon: 0.101333,
                       sampleBuildMs: 0.1, rendererEnqueueMs: 0.05, wallTime: 1234.5)
        let event = try XCTUnwrap(trace.events.last)
        XCTAssertEqual(event["reasons"] as? [String], ["routeHorizon", "receiveGap"])
        XCTAssertEqual(try XCTUnwrap(event["receiveGapMs"] as? Double), 130, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(event["mainIngressWaitMs"] as? Double), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(event["playbackWaitMs"] as? Double), 1, accuracy: 0.0001)
        XCTAssertEqual(event["sourceTimestampStepMs"] as? Double, 20)
        XCTAssertEqual(event["observedAtUnixSeconds"] as? Double, 1234.5)
        XCTAssertEqual(trace.pendingCount, 0)
    }

    func testAudioTraceAttributesMainQueueDelayAndRetainsRouteWarning() throws {
        var trace = BenchmarkAudioTrace()
        trace.received(1, at: 2)
        trace.delivered(1, at: 2.001)
        trace.queued(1, at: 2.101)
        trace.admitted(1, at: 2.103, lead: 0.1, horizon: 0.101333,
                       sampleBuildMs: 0.2, rendererEnqueueMs: 0.3)
        let event = try XCTUnwrap(trace.events.last)
        XCTAssertEqual(event["reasons"] as? [String], ["routeHorizon", "mainIngressWait"])
        XCTAssertEqual(try XCTUnwrap(event["mainIngressWaitMs"] as? Double), 100, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(event["receiveToAdmissionMs"] as? Double), 103, accuracy: 0.0001)
    }

    func testAudioTraceBoundsStorageAndClearsStagesAcrossConnections() {
        var trace = BenchmarkAudioTrace()
        for index in 0..<1000 { trace.received(Int64(index), at: Double(index)) }
        XCTAssertEqual(trace.pendingCount, 64)
        for index in 0..<100 {
            trace.admitted(Int64(index), at: Double(index), lead: 0.05, horizon: 0.1,
                           sampleBuildMs: 0, rendererEnqueueMs: 0)
        }
        XCTAssertEqual(trace.eventCount, 100)
        XCTAssertEqual(trace.events.count, 32)
        XCTAssertEqual(trace.firstRouteWarnings.count, 32)
        XCTAssertEqual(trace.firstRouteWarnings.first?["sourceTimestamp100ns"] as? Int64, 0)
        XCTAssertEqual(trace.events.first?["sourceTimestamp100ns"] as? Int64, 68)
        trace.resetConnection()
        XCTAssertEqual(trace.pendingCount, 0)
        trace.received(1, at: 2000)
        trace.admitted(1, at: 2000.001, lead: 0.2, horizon: 0.1,
                       sampleBuildMs: 0, rendererEnqueueMs: 0)
        XCTAssertEqual(trace.eventCount, 100)
    }

    func testUnavailableLeadCannotBreakExceptionalTimingReportSerialization() {
        var trace = BenchmarkAudioTrace()
        trace.admitted(1, at: 1, lead: .nan, horizon: 0.1,
                       sampleBuildMs: 25, rendererEnqueueMs: 0)
        trace.admitted(2, at: 1.020, lead: 0.2, horizon: 0.1,
                       sampleBuildMs: 25, rendererEnqueueMs: 0)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(trace.summary))
        XCTAssertNil(trace.events[0]["leadMs"])
        XCTAssertNil(trace.events[1]["previousLeadMs"])
        XCTAssertEqual(trace.firstRouteWarnings.count, 0)
    }

    func testOrdinaryAndAddressOnlyLaunchesNeverEnableBenchmark() throws {
        XCTAssertNil(try ReceiverBenchmarkConfiguration.parse(["app"]))
        XCTAssertNil(try ReceiverBenchmarkConfiguration.parse(["app", "--omt-benchmark-source", "omt://127.0.0.1:6488"]))
    }

    func testBenchmarkRequiresValidUniqueRunIDAndExplicitValidSource() throws {
        let id = UUID().uuidString
        let configuration = try XCTUnwrap(ReceiverBenchmarkConfiguration.parse(["app", "--omt-benchmark-run", id, "--omt-benchmark-source", "omt://127.0.0.1:6488"]))
        XCTAssertEqual(configuration.runID.uuidString, id)
        XCTAssertEqual(configuration.source.name, "127.0.0.1:6488")
        XCTAssertThrowsError(try ReceiverBenchmarkConfiguration.parse(["app", "--omt-benchmark-run", "../old"]))
        XCTAssertThrowsError(try ReceiverBenchmarkConfiguration.parse(["app", "--omt-benchmark-run", id]))
        XCTAssertThrowsError(try ReceiverBenchmarkConfiguration.parse(["app", "--omt-benchmark-run", id, "--omt-benchmark-run", id, "--omt-benchmark-source", "omt://127.0.0.1:6488"]))
        XCTAssertThrowsError(try ReceiverBenchmarkConfiguration.parse(["app", "--omt-benchmark-run", id, "--omt-benchmark-source", "https://invalid/"]))
    }

    func testHistogramPercentilesRetainOutliersAndRejectInvalidMeasurements() {
        var histogram = BenchmarkHistogram()
        for index in 1...100 { histogram.record(Double(index) / 10) }
        histogram.record(.nan); histogram.record(-1); histogram.record(.infinity)
        XCTAssertEqual(histogram.count, 100)
        XCTAssertEqual(histogram.percentileUpperBound(0.50), 5)
        XCTAssertEqual(histogram.percentileUpperBound(0.95), 9.5)
        XCTAssertEqual(histogram.percentileUpperBound(0.99), 10)
        histogram.record(1500)
        XCTAssertEqual(histogram.summary["maximum"] as? Double, 1500)
        XCTAssertNil(histogram.percentileUpperBound(1))
        XCTAssertEqual(histogram.summary["overflowAbove1000ms"] as? UInt64, 1)
    }

    func testDefaultBenchmarkStorageCanBeCreatedInTheNativeTVOSContainer() throws {
        let configuration = try XCTUnwrap(ReceiverBenchmarkConfiguration.parse(["app", "--omt-benchmark-run", UUID().uuidString, "--omt-benchmark-source", "omt://127.0.0.1:6488"]))
        // Exercise the production directory selection, not an injected /tmp
        // path: tvOS rejects Documents even though that API exists in its SDK.
        let benchmark = try ReceiverBenchmark(configuration: configuration)
        withExtendedLifetime(benchmark) {}
    }

    func testReusingRunIDCannotOverwriteOrMixExistingEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try XCTUnwrap(ReceiverBenchmarkConfiguration.parse(["app", "--omt-benchmark-run", UUID().uuidString, "--omt-benchmark-source", "omt://127.0.0.1:6488"]))
        let first = try ReceiverBenchmark(configuration: configuration, directory: directory)
        XCTAssertThrowsError(try ReceiverBenchmark(configuration: configuration, directory: directory))
        withExtendedLifetime(first) {}
    }
}
