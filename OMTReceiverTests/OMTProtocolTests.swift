import XCTest
import Network
@testable import OMTReceiver

final class OMTProtocolTests: XCTestCase {
    func testOfficialSenderTallyWireFixtureWithoutTerminator() throws {
        // Exact bytes from the upstream sender's OMTMetadata.FromTally ->
        // OMTChannel.Send -> OMTBuffer.FromMetadata path. The last byte is '>',
        // and DataLength is 45: its UTF8.GetBytes result excludes a terminator.
        // This fixture deliberately does not use our command/frame serializer.
        let bytes = Data([
            0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2d, 0x00, 0x00, 0x00,
            0x3c, 0x4f, 0x4d, 0x54, 0x54, 0x61, 0x6c, 0x6c, 0x79, 0x20, 0x50, 0x72, 0x65, 0x76, 0x69, 0x65,
            0x77, 0x3d, 0x22, 0x66, 0x61, 0x6c, 0x73, 0x65, 0x22, 0x20, 0x50, 0x72, 0x6f, 0x67, 0x72, 0x61,
            0x6d, 0x3d, 0x3d, 0x22, 0x66, 0x61, 0x6c, 0x73, 0x65, 0x22, 0x20, 0x2f, 0x3e
        ])
        var parser = OMTProtocolParser()
        var received: String?
        try parser.append(bytes) { if case .metadata(let string) = $0 { received = string } }
        XCTAssertEqual(received, "<OMTTally Preview=\"false\" Program==\"false\" />")
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testExactMetadataFramingAndCompatibilityStrings() throws {
        let frame = OMTCommands.frame(OMTCommands.subscribeVideo)
        XCTAssertEqual(Array(frame.prefix(12)), [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(frame[12], UInt8(OMTCommands.subscribeVideo.utf8.count))
        XCTAssertEqual(frame.suffix(from: 16), Data(OMTCommands.subscribeVideo.utf8), "Official exact-string subscriptions cannot include a NUL")
        XCTAssertEqual(frame.last, 0x3e)
        XCTAssertEqual(OMTCommands.tally(program: true), "<OMTTally Preview=\"false\" Program==\"true\" />")
        XCTAssertEqual(OMTCommands.tally(program: false), "<OMTTally Preview=\"false\" Program==\"false\" />")
        XCTAssertEqual(OMTCommands.quality(.default), "<OMTSettings Quality=\"Default\" />")
        XCTAssertEqual(OMTCommands.quality(.high), "<OMTSettings Quality=\"High\" />")
        XCTAssertEqual(OMTCommands.fullResolution, "<OMTSettings Preview=\"false\" />")
        var parser = OMTProtocolParser()
        var result: String?
        try parser.append(frame) { if case .metadata(let text) = $0 { result = text } }
        XCTAssertEqual(result, OMTCommands.subscribeVideo)
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testByteByByteFragmentationPreservesHeaderAndPayload() throws {
        let bytes = video(timestamp: 123_456_789, metadata: "<Frame Name=\"例\" />")
        var parser = OMTProtocolParser()
        var packets: [OMTPacket] = []
        for byte in bytes { try parser.append(Data([byte])) { packets.append($0) } }
        XCTAssertEqual(packets.count, 2)
        guard case .video(let frame) = packets.first else { return XCTFail("Missing video") }
        XCTAssertEqual(frame.timestamp, 123_456_789)
        XCTAssertEqual(frame.codec, OMTCodec.vmx1)
        XCTAssertEqual(frame.width, 1_920)
        XCTAssertEqual(frame.height, 1_080)
        XCTAssertEqual(frame.frameRateN, 30_000)
        XCTAssertEqual(frame.frameRateD, 1_001)
        XCTAssertEqual(frame.aspectRatio, 16 / 9, accuracy: 0.0001)
        XCTAssertEqual(frame.flags, 2)
        XCTAssertEqual(frame.colorSpace, 709)
        XCTAssertEqual(frame.payload, Data([0x10, 0x20, 0x30, 0x40]))
        guard case .metadata(let xml) = packets.last else { return XCTFail("Missing per-frame metadata") }
        XCTAssertEqual(xml, "<Frame Name=\"例\" />")
    }

    func testCoalescedFramesAndEveryTwoChunkBoundary() throws {
        let input = video(timestamp: 1) + OMTCommands.frame("<OMTInfo ProductName=\"External\" />") + audio(active: 0b10, payload: floatBytes([0.25, -0.25]))
        for split in 0...input.count {
            var parser = OMTProtocolParser()
            var packets: [OMTPacket] = []
            try parser.append(input.prefix(split)) { packets.append($0) }
            try parser.append(input.suffix(input.count - split)) { packets.append($0) }
            XCTAssertEqual(packets.count, 3, "TCP boundary \(split)")
            guard case .audio(let frame) = packets.last else { return XCTFail("Missing coalesced audio") }
            XCTAssertEqual(frame.channels, 2)
            XCTAssertEqual(frame.activeChannels, 0b10)
            XCTAssertEqual(frame.payload, floatBytes([0.25, -0.25]))
        }
    }

    func testHeaderRejectsNegativeOversizeAndTruncatedExtendedLengthsBeforeAllocation() {
        for count in [Int32(-1), Int32.max, Int32(31)] {
            var header = Data([1, 2])
            header.omtAppend(UInt64(0)); header.omtAppend(UInt16(0)); header.omtAppend(count)
            var parser = OMTProtocolParser()
            XCTAssertThrowsError(try parser.append(header) { _ in XCTFail("Malformed frame escaped") })
            XCTAssertLessThanOrEqual(parser.bufferedByteCount, 16)
        }
        var badVersion = OMTCommands.frame("<Info />")
        badVersion[0] = 2
        var parser = OMTProtocolParser()
        XCTAssertThrowsError(try parser.append(badVersion) { _ in })
    }

    func testUnknownFrameTypeAndMetadataLongerThanBodyAreRejected() {
        var header = Data([1, 8])
        header.omtAppend(UInt64(0)); header.omtAppend(UInt16(0)); header.omtAppend(UInt32(8))
        var parser = OMTProtocolParser()
        XCTAssertThrowsError(try parser.append(header) { _ in })
        header[1] = 2
        header[10] = 20
        header[12] = 40
        parser = OMTProtocolParser()
        XCTAssertThrowsError(try parser.append(header) { _ in })
    }

    func testInvalidMetadataCannotDeliverItsVideoFirst() {
        var invalidUTF8 = video(metadata: "<Frame />")
        invalidUTF8[invalidUTF8.count - 1] = 0xff
        var embeddedNull = video(metadata: "<Frame />")
        embeddedNull[embeddedNull.count - 4] = 0
        for frame in [invalidUTF8, embeddedNull] {
            var parser = OMTProtocolParser()
            XCTAssertThrowsError(try parser.append(frame) { _ in XCTFail("Invalid metadata frame was admitted") })
        }
    }

    func testMetadataAllowsOneOptionalTerminatorForStandaloneAndPerFrameBytes() throws {
        let xml = "<Frame Name=\"例\" />"
        for terminated in [false, true] {
            let payload = Data(xml.utf8) + (terminated ? Data([0]) : Data())
            var parser = OMTProtocolParser()
            var metadata: [String] = []
            let standalone = packet(type: 1, timestamp: 0, metadataLength: 0, body: payload)
            try parser.append(standalone + video(metadata: xml, terminatedMetadata: terminated)) {
                if case .metadata(let value) = $0 { metadata.append(value) }
            }
            XCTAssertEqual(metadata, [xml, xml])
        }
        for malformed in [Data([0xc3, 0x28]), Data([0x3c, 0, 0x3e]), Data([0x3c, 0x3e, 0, 0])] {
            var parser = OMTProtocolParser()
            let frame = packet(type: 1, timestamp: 0, metadataLength: 0, body: malformed)
            XCTAssertThrowsError(try parser.append(frame) { _ in XCTFail("Malformed UTF-8 or embedded NUL escaped") })
        }
    }

    func testSparseAndCompletelySilentAudioAreValidWithoutInventingStoredPlanes() throws {
        var parser = OMTProtocolParser()
        var frames: [OMTAudioFrame] = []
        let sparse = audio(active: 0b10, payload: floatBytes([1, -1]))
        let silent = audio(active: 0, payload: Data())
        try parser.append(sparse + silent) { if case .audio(let frame) = $0 { frames.append(frame) } }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].payload.count, 8)
        XCTAssertEqual(frames[0].samplesPerChannel, 2)
        XCTAssertEqual(frames[0].activeChannels, 2)
        XCTAssertTrue(frames[1].payload.isEmpty)
        XCTAssertEqual(frames[1].channels, 2)
    }

    func testAudioRejectsOutOfRangeMasksWrongPayloadAndImpossibleDecodedSize() {
        let cases = [
            audio(active: 0b100, payload: floatBytes([1, 2])),
            audio(active: 0b11, payload: floatBytes([1, 2])),
            audio(active: 0, payload: floatBytes([1, 2])),
            audio(active: 0, payload: Data(), channels: 33),
            audio(active: 0, payload: Data(), samples: 100_000, channels: 32),
            audio(active: 0, payload: Data(), samples: -1),
            audio(active: 0, payload: Data(), rate: 0)
        ]
        for input in cases {
            var parser = OMTProtocolParser()
            XCTAssertThrowsError(try parser.append(input) { _ in XCTFail("Malformed sparse audio escaped") })
        }
    }

    func testThirtySecondBitIsHandledAsUnsignedAudioMask() throws {
        var parser = OMTProtocolParser()
        var frame: OMTAudioFrame?
        try parser.append(audio(active: 1 << 31, payload: floatBytes([0.5, 1]), channels: 32)) {
            if case .audio(let value) = $0 { frame = value }
        }
        XCTAssertEqual(frame?.activeChannels, 0x8000_0000)
    }

    func testVideoBoundsNaNAspectAndInvalidFrameRate() {
        for frame in [video(width: 0), video(width: 65_536), video(height: -1), video(numerator: 0), video(denominator: 0), video(aspect: .nan)] {
            var parser = OMTProtocolParser()
            XCTAssertThrowsError(try parser.append(frame) { _ in XCTFail("Malformed video escaped") })
        }
    }

    func testSigned32BitVideoRatesPreserveExactTermsTimestampAndPayload() throws {
        let rates: [(Int32, Int32)] = [
            (3_000_003, 100_000), // Logitech StreamCam's actual OMT Camera rate.
            (3_000_030, 100_001), // Both terms exceed the former arbitrary caps.
            (.max, 10_000_000), (.max, .max), (1, .max),
            (240, 1), (2_147_483_520, 8_947_848) // Exactly 240 fps, including large terms.
        ]
        for (n, d) in rates {
            let timestamp: UInt64 = 12_345_678_901
            let bytes = video(timestamp: timestamp, numerator: n, denominator: d,
                              flags: 0, metadata: "<Frame Rate=\"exact\" />")
            var parser = OMTProtocolParser()
            var packets: [OMTPacket] = []
            // Exercise signed rate parsing across arbitrary transport splits.
            for byte in bytes { try parser.append(Data([byte])) { packets.append($0) } }
            XCTAssertEqual(packets.count, 2)
            guard case .video(let frame) = packets.first else { return XCTFail("Missing video at \(n)/\(d)") }
            XCTAssertEqual(frame.frameRateN, Int(n))
            XCTAssertEqual(frame.frameRateD, Int(d))
            XCTAssertEqual(frame.timestamp, Int64(timestamp))
            XCTAssertEqual(frame.payload, Data([0x10, 0x20, 0x30, 0x40]))
            XCTAssertEqual(frame.flags, 0)
            guard case .metadata(let metadata) = packets.last else { return XCTFail("Missing frame metadata") }
            XCTAssertEqual(metadata, "<Frame Rate=\"exact\" />")
            XCTAssertEqual(parser.bufferedByteCount, 0)
        }
    }

    func testVideoRateRejectsNonpositiveSignedTermsAndUnsignedHighBitPatterns() {
        // UInt32 values beyond Int32.max are negative OMT wire terms, not
        // additional positive rates. Check each term independently.
        for term in [Int32(0), -1, Int32(bitPattern: 0x8000_0000), Int32(bitPattern: 0xffff_ffff)] {
            for bytes in [video(numerator: term), video(denominator: term)] {
                var parser = OMTProtocolParser()
                XCTAssertThrowsError(try parser.append(bytes) { _ in XCTFail("Invalid signed rate escaped") })
            }
        }
    }

    func testVideoRateRetainsExact240FPSLimitForLargeTerms() {
        let rates: [(Int32, Int32)] = [(241, 1), (240_001, 1_000), (2_147_483_521, 8_947_848)]
        for (n, d) in rates {
            var parser = OMTProtocolParser()
            XCTAssertThrowsError(try parser.append(video(numerator: n, denominator: d)) { _ in
                XCTFail("Rate above 240 fps escaped: \(n)/\(d)")
            })
        }
    }

    func testOfficialOBSZeroAspectAndColorDefaultsDeriveSquarePixels() throws {
        let dimensions: [(Int32, Int32)] = [(1_280, 720), (32, 16)]
        for (width, height) in dimensions {
            var parser = OMTProtocolParser()
            var received: OMTVideoFrame?
            try parser.append(video(width: width, height: height, numerator: 30, denominator: 1,
                                    aspect: 0, flags: 0, color: 0)) {
                if case .video(let frame) = $0 { received = frame }
            }
            let frame = try XCTUnwrap(received)
            XCTAssertEqual(frame.aspectRatio, Float(width) / Float(height), accuracy: 0.0001)
            XCTAssertEqual(frame.colorSpace, 0, "Preserve the SDK's undefined color-space value")
            XCTAssertEqual(frame.flags, 0)
        }
    }

    func testExplicitAnamorphicAspectRatioIsPreserved() throws {
        var parser = OMTProtocolParser()
        var aspect: Float?
        try parser.append(video(width: 720, height: 576, aspect: 16 / 9)) {
            if case .video(let frame) = $0 { aspect = frame.aspectRatio }
        }
        XCTAssertEqual(try XCTUnwrap(aspect), 16 / 9, accuracy: 0.0001)
    }

    func testUnspecifiedAspectStillRejectsInvalidGeometryAndAspectValues() {
        let invalid: [Data] = [
            video(width: 0, aspect: 0), video(height: 0, aspect: 0),
            video(width: -1, aspect: 0), video(width: 4_096, height: 1, aspect: 0),
            video(aspect: -1), video(aspect: .nan), video(aspect: .infinity),
            video(aspect: -.infinity), video(aspect: 101)
        ]
        for bytes in invalid {
            var parser = OMTProtocolParser()
            XCTAssertThrowsError(try parser.append(bytes) { _ in XCTFail("Invalid geometry or aspect escaped") })
        }
    }

    func testManualAddressRequiresExplicitValidPortAndSupportsIPv6() throws {
        let source = try OMTSource.manual(address: "omt://192.168.1.2:6400")
        XCTAssertEqual(source.name, "192.168.1.2:6400")
        let ipv6 = try OMTSource.manual(address: "omt://[::1]:6401")
        guard case .hostPort(let host, let port) = ipv6.endpoint else { return XCTFail("Not a TCP endpoint") }
        XCTAssertEqual(host, NWEndpoint.Host("::1"))
        XCTAssertEqual(port.rawValue, 6401)
        XCTAssertEqual(try OMTSource.manual(address: "host.local:6400").name, "host.local:6400")
        for address in ["", "omt://host", "omt://host:0", "omt://host:65536", "https://host:6400", "omt://user@host:6400", "omt://host:6400/path", "omt://host:6400?key=value"] {
            XCTAssertThrowsError(try OMTSource.manual(address: address), address)
        }
    }

    func testRedirectMetadataAllowsNoRedirectAndDecodesEscapedDestination() throws {
        XCTAssertEqual(try OMTRedirectMetadata.destination("<OMTRedirect NewAddress=\"\" />"), "")
        XCTAssertEqual(try OMTRedirectMetadata.destination("<OMTRedirect NewAddress=\"HOST (A &amp; B)\" />"), "HOST (A & B)")
        XCTAssertThrowsError(try OMTRedirectMetadata.destination("<OMTRedirect />"))
        XCTAssertThrowsError(try OMTRedirectMetadata.destination("<!DOCTYPE x [<!ENTITY a 'x'>]><OMTRedirect NewAddress=\"&a;\" />"))
    }

    private func video(timestamp: UInt64 = 1, width: Int32 = 1_920, height: Int32 = 1_080,
                       numerator: Int32 = 30_000, denominator: Int32 = 1_001, aspect: Float = 16 / 9,
                       flags: UInt32 = 2, color: Int32 = 709, metadata: String? = nil, terminatedMetadata: Bool = true) -> Data {
        var body = Data()
        body.omtAppend(OMTCodec.vmx1); body.omtAppend(width); body.omtAppend(height)
        body.omtAppend(numerator); body.omtAppend(denominator); body.omtAppend(aspect.bitPattern)
        body.omtAppend(flags); body.omtAppend(color)
        body.append(contentsOf: [0x10, 0x20, 0x30, 0x40])
        let text = metadata.map { Data($0.utf8) + (terminatedMetadata ? Data([0]) : Data()) } ?? Data()
        body.append(text)
        return packet(type: 2, timestamp: timestamp, metadataLength: UInt16(text.count), body: body)
    }

    private func audio(active: UInt32, payload: Data, samples: Int32 = 2, channels: Int32 = 2, rate: Int32 = 48_000) -> Data {
        var body = Data()
        body.omtAppend(OMTCodec.fpa1); body.omtAppend(rate); body.omtAppend(samples); body.omtAppend(channels)
        body.omtAppend(active); body.omtAppend(UInt32(0)); body.append(payload)
        return packet(type: 4, timestamp: 42, metadataLength: 0, body: body)
    }

    private func packet(type: UInt8, timestamp: UInt64, metadataLength: UInt16, body: Data) -> Data {
        var result = Data([1, type])
        result.omtAppend(timestamp); result.omtAppend(metadataLength); result.omtAppend(UInt32(body.count))
        result.append(body)
        return result
    }

    private func floatBytes(_ values: [Float]) -> Data {
        values.reduce(into: Data()) { $0.omtAppend($1.bitPattern) }
    }
}
