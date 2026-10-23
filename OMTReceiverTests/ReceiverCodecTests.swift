import CoreMedia
import CoreVideo
import Compression
import XCTest
@testable import OMTReceiver

final class ReceiverCodecTests: XCTestCase {
    // Generated with the vendored upstream VMX encoder, 32x16 BT.709. Source
    // BGRA is (x, y, 200, 128), or BGRX without the alpha plane. These fixtures
    // exercise the real SIMD decoder rather than a stand-in codec.
    private let opaque = Data(base64Encoded: "AwMBUAEOAAAAAST2d7ABujwoPADWoiAbAAAApQfqD9QfqD9QfqD9QfqD0NQfqD9QfqD4gEAA")!
    private let alpha = Data(base64Encoded: "AwMBUAEQAAAAAST2d7ABujwoPADWoiD//x4AAAClB+oP1B+oP1B+oP1B+oPQ1B+oP1B+oPiAQACAIAA=")!
    private let black = Data(base64Encoded: "AwMBUAEKAAAAAcH/+ACA/gCA/gkAAACAIACAQACAQAA=")!
    // Encoded RGB is deliberately colorful (53,141,211), with alpha zero.
    private let transparent = Data(base64Encoded: "AwMBUAEOAAAABH//gAFL+ACi/gCAf/4MAAAAgCAAgEAAgEAAgCAA")!

    private func frame(_ bytes: Data, flags: UInt32 = 0, width: Int = 32) -> OMTVideoFrame {
        .init(timestamp: 0, codec: OMTCodec.vmx1, width: width, height: 16, frameRateN: 30, frameRateD: 1,
              aspectRatio: 2, flags: flags, colorSpace: 709, payload: bytes)
    }

    func testOfficialOpaqueFixtureUsesTaggedPackedYUV() throws {
        let image = try XCTUnwrap(VMXFrameDecoder().decode(frame(opaque)))
        XCTAssertEqual(CVPixelBufferGetWidth(image), 32)
        XCTAssertEqual(CVPixelBufferGetHeight(image), 16)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_422YpCbCr8)
        let matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil)
        XCTAssertEqual(matrix as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    func testUnspecifiedAspectReachesDecoderAsSquarePixelAttachment() throws {
        var body = Data()
        body.omtAppend(OMTCodec.vmx1)
        for value: Int32 in [32, 16, 30, 1] { body.omtAppend(value) }
        body.omtAppend(Float(0).bitPattern)
        body.omtAppend(UInt32(0)); body.omtAppend(Int32(0))
        body.append(opaque)
        var bytes = Data([1, 2])
        bytes.omtAppend(UInt64(0)); bytes.omtAppend(UInt16(0)); bytes.omtAppend(UInt32(body.count))
        bytes.append(body)
        var parser = OMTProtocolParser()
        var parsed: OMTVideoFrame?
        try parser.append(bytes) { if case .video(let frame) = $0 { parsed = frame } }
        let image = try XCTUnwrap(VMXFrameDecoder().decode(try XCTUnwrap(parsed)))
        let spacing = try XCTUnwrap(CVBufferCopyAttachment(image, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Int])
        XCTAssertEqual(spacing[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String], 10_000)
        XCTAssertEqual(spacing[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String], 10_000)
    }

    func testStraightAndPremultipliedAlphaCompositeOntoOpaqueBlack() throws {
        let straight = try XCTUnwrap(VMXFrameDecoder().decode(frame(alpha, flags: 2)))
        let premultiplied = try XCTUnwrap(VMXFrameDecoder().decode(frame(alpha, flags: 6)))
        CVPixelBufferLockBaseAddress(straight, .readOnly)
        CVPixelBufferLockBaseAddress(premultiplied, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(straight, .readOnly)
            CVPixelBufferUnlockBaseAddress(premultiplied, .readOnly)
        }
        let a = try XCTUnwrap(CVPixelBufferGetBaseAddress(straight)?.assumingMemoryBound(to: UInt8.self))
        let b = try XCTUnwrap(CVPixelBufferGetBaseAddress(premultiplied)?.assumingMemoryBound(to: UInt8.self))
        for x in 0..<32 {
            XCTAssertEqual(a[x * 4 + 3], 255)
            XCTAssertEqual(b[x * 4 + 3], 255)
            XCTAssertEqual(Int(a[x * 4 + 2]), Int(b[x * 4 + 2]) / 2, accuracy: 2)
        }
    }

    func testBlackAndTransparentClearFramesReplacePreviouslyColoredPixels() throws {
        let decoder = VMXFrameDecoder()
        _ = try XCTUnwrap(decoder.decode(frame(opaque)))
        let opaqueBlack = try XCTUnwrap(decoder.decode(frame(black)))
        CVPixelBufferLockBaseAddress(opaqueBlack, .readOnly)
        let yuv = try XCTUnwrap(CVPixelBufferGetBaseAddress(opaqueBlack)?.assumingMemoryBound(to: UInt8.self))
        for y in 0..<16 {
            let row = yuv + y * CVPixelBufferGetBytesPerRow(opaqueBlack)
            for x in stride(from: 0, to: 64, by: 4) {
                XCTAssertEqual(Array(UnsafeBufferPointer(start: row + x, count: 4)), [128, 16, 128, 16])
            }
        }
        CVPixelBufferUnlockBaseAddress(opaqueBlack, .readOnly)
        _ = try XCTUnwrap(decoder.decode(frame(alpha, flags: 2)))
        let cleared = try XCTUnwrap(decoder.decode(frame(transparent, flags: 2)))
        CVPixelBufferLockBaseAddress(cleared, .readOnly)
        let bgra = try XCTUnwrap(CVPixelBufferGetBaseAddress(cleared)?.assumingMemoryBound(to: UInt8.self))
        for y in 0..<16 {
            let row = bgra + y * CVPixelBufferGetBytesPerRow(cleared)
            for x in 0..<32 {
                XCTAssertEqual(Array(UnsafeBufferPointer(start: row + x * 4, count: 4)), [0, 0, 0, 255])
            }
        }
        CVPixelBufferUnlockBaseAddress(cleared, .readOnly)
    }

    func testAllTruncationsAndInconsistentDimensionsAreRejected() {
        let decoder = VMXFrameDecoder()
        for end in 0..<opaque.count {
            XCTAssertThrowsError(try decoder.decode(frame(Data(opaque.prefix(end)))))
        }
        XCTAssertThrowsError(try decoder.decode(frame(opaque, width: 64)))
        var bad = opaque
        bad[1] = 255 // Invalid extended DC shift, previously unchecked upstream.
        XCTAssertThrowsError(try decoder.decode(frame(bad)))
        bad = opaque; bad[4] = 2 // Payload has one slice, header claims two.
        XCTAssertThrowsError(try decoder.decode(frame(bad)))
        bad = opaque; bad[bad.count - 1] = 0xff // Nonzero trailing plane padding.
        XCTAssertThrowsError(try decoder.decode(frame(bad)))
    }

    func testUnsupportedPreviewHighBitDepthAndUnknownFlagsFailClearly() {
        for flag: UInt32 in [8, 16, 32] {
            XCTAssertThrowsError(try VMXFrameDecoder().decode(frame(opaque, flags: flag))) { error in
                XCTAssertTrue(error.localizedDescription.contains("progressive"))
            }
        }
    }

    func testSurfacePoolDoesNotGrowWhenConsumerRetainsFrames() throws {
        let decoder = VMXFrameDecoder()
        var held: [CVPixelBuffer] = []
        for _ in 0..<10 { held.append(try XCTUnwrap(decoder.decode(frame(opaque)))) }
        XCTAssertNil(try decoder.decode(frame(opaque)))
        held.removeAll()
        XCTAssertNotNil(try decoder.decode(frame(opaque)))
    }

    func testCapturedOfficialSDKFourPlaneVideoCanAdvertiseOpaqueOutput() throws {
        let payload = try officialSDKPayload()
        let frame = officialSDKFrame(payload)
        let image = try XCTUnwrap(VMXFrameDecoder().decode(frame))
        XCTAssertEqual(CVPixelBufferGetWidth(image), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(image), 1080)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_422YpCbCr8)
    }

    func testCapturedSDKExtraPlaneStillRejectsMalformedEntropyAndTruncation() throws {
        let payload = try officialSDKPayload()
        XCTAssertThrowsError(try VMXFrameDecoder().decode(officialSDKFrame(Data(payload.dropLast()))))
        // The first SDK DC slice is507 bytes. Its first three complete planes
        // end at byte384; corrupt only the remaining encoded alpha plane.
        var corrupt = payload
        corrupt.replaceSubrange(391..<514, with: repeatElement(UInt8(0), count: 123))
        XCTAssertThrowsError(try VMXFrameDecoder().decode(officialSDKFrame(corrupt)))
    }

    func testFullHD60AndFractional60UseTheRealSDKDecoder() throws {
        let payload = try officialSDKPayload()
        for (n, d) in [(60, 1), (60000, 1001), (50, 1), (30, 1)] {
            let image = try XCTUnwrap(VMXFrameDecoder().decode(officialSDKFrame(payload, numerator: n, denominator: d)))
            XCTAssertEqual(CVPixelBufferGetWidth(image), 1920)
            XCTAssertEqual(CVPixelBufferGetHeight(image), 1080)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_422YpCbCr8)
        }
    }

    func testAbove60And4KRemainUnsupportedBeforeDecode() throws {
        let payload = try officialSDKPayload()
        let rejected = [officialSDKFrame(payload, numerator: 61),
                        officialSDKFrame(payload, numerator: 60001, denominator: 1000),
                        officialSDKFrame(payload, numerator: 60, width: 3840, height: 2160)]
        for frame in rejected {
            XCTAssertThrowsError(try VMXFrameDecoder().decode(frame)) { error in
                guard let failure = error as? PlaybackFailure else { return XCTFail("Unexpected error: \(error)") }
                switch failure {
                case .unsupportedVideo: break
                default: XCTFail("Unsupported format reached codec validation: \(error)")
                }
            }
        }
    }

    private func officialSDKFrame(_ payload: Data, numerator: Int = 30, denominator: Int = 1, width: Int = 1920, height: Int = 1080) -> OMTVideoFrame {
        .init(timestamp: 788_000_000, codec: OMTCodec.vmx1, width: width, height: height,
              frameRateN: numerator, frameRateD: denominator, aspectRatio: 16 / 9, flags: 0, colorSpace: 709, payload: payload)
    }

    private func officialSDKPayload() throws -> Data {
        let packed = try XCTUnwrap(Data(base64Encoded: Self.officialSDKDeflate, options: .ignoreUnknownCharacters))
        var output = Data(count: 52_103)
        let count = output.withUnsafeMutableBytes { destination in
            packed.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, 52_103,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        XCTAssertEqual(count, 52_103)
        guard count == 52_103 else { throw PlaybackFailure.allocation }
        return output
    }
}

// Exact unmodified frame captured from official OMT SDK1.0.0.19 on localhost.
// Metadata:1920x1080p30, BT.709, flags0; compressed payload hasfour planes.
// SHA256:7b66c14766635f1c31d75f28574d474b83268f245e88de6d1517eca09e241074
// Raw DEFLATE keeps the52103-byte independent interoperability fixture compact.
private extension ReceiverCodecTests {
    static let officialSDKDeflate = """
    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
    """
}
