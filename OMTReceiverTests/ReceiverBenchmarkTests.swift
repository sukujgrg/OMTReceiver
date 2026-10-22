import Foundation
import XCTest
@testable import OMTReceiver

final class ReceiverBenchmarkTests: XCTestCase {
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
