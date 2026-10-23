import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import OMTReceiver

final class ReceiverInterlacedCodecTests: XCTestCase {
    // Real VMX encoder output, 32x480, BT.709. The upper field's bright bar is
    // x8...15, the lower field's is x16...23, representing horizontal motion
    // between fields. Every output row must come from the chosen field only.
    private func frame(_ payload: Data = InterlacedFixture.interlaced, flags: UInt32 = 1, height: Int = 480) -> OMTVideoFrame {
        .init(timestamp: 0, codec: OMTCodec.vmx1, width: 32, height: height,
              frameRateN: 30, frameRateD: 1, aspectRatio: 4 / 3, flags: flags, colorSpace: 709, payload: payload)
    }

    func testActualInterlacedEntropyProducesTwoDistinctProgressiveMovingFields() throws {
        let decoder = VMXFrameDecoder()
        let images = try XCTUnwrap(decoder.decode(frame(), fields: [0, 1]))
        XCTAssertEqual(images.count, 2)
        guard try assertField(images[0], brightX: 8, darkX: 16),
              try assertField(images[1], brightX: 16, darkX: 8) else { return }
        for image in images {
            XCTAssertEqual(CVBufferCopyAttachment(image, kCVImageBufferFieldCountKey, nil) as? Int, 1)
        }
    }

    func testBottomFirstOrderSelectsTheActualLowerFieldPixelsFirst() throws {
        let source = frame()
        let cadence = try ReceiverVideoCadence(frame: source, fieldOrder: .bottomFirst)
        let images = try XCTUnwrap(VMXFrameDecoder().decode(source, fields: cadence.samples.map(\.field)))
        guard try assertField(images[0], brightX: 16, darkX: 8),
              try assertField(images[1], brightX: 8, darkX: 16) else { return }
    }

    func testInterlacedBatchAllocationIsAtomicWithinTheOriginalTenSurfaceLimit() throws {
        let decoder = VMXFrameDecoder()
        var held: [CVPixelBuffer] = []
        for _ in 0..<4 { held += try XCTUnwrap(decoder.decode(frame(), fields: [0, 1])) }
        held += try XCTUnwrap(decoder.decode(frame(), fields: [1]))
        XCTAssertEqual(held.count, 9)
        // Nine held outputs leave one slot. Reserving both outputs must fail
        // before decode and release its partial allocation for the next caller.
        XCTAssertNil(try decoder.decode(frame(), fields: [0, 1]))
        held += try XCTUnwrap(decoder.decode(frame(), fields: [0]))
        XCTAssertEqual(held.count, VMXFrameDecoder.maximumRetainedFrames)
        XCTAssertNil(try decoder.decode(frame(), fields: [1]))
        held.removeAll()
        XCTAssertEqual(try XCTUnwrap(decoder.decode(frame(), fields: [0, 1])).count, 2)
    }

    func testResetCannotAllocatePastTenWhileOldInterlacedOutputsRemainHeld() throws {
        let decoder = VMXFrameDecoder()
        var retired: [CVPixelBuffer] = []
        for _ in 0..<4 { retired += try XCTUnwrap(decoder.decode(frame(), fields: [0, 1])) }
        retired += try XCTUnwrap(decoder.decode(frame(), fields: [1]))
        decoder.reset()
        // Nine retiring outputs leave one slot. A two-field decode needs two
        // outputs atomically even though its woven image becomes an output.
        try withExtendedLifetime(retired) { XCTAssertNil(try decoder.decode(frame(), fields: [0, 1])) }
        retired.removeLast()
        let current = try XCTUnwrap(decoder.decode(frame(), fields: [0, 1]))
        XCTAssertEqual(current.count + retired.count, VMXFrameDecoder.maximumRetainedFrames)
        try withExtendedLifetime((retired, current)) { XCTAssertNil(try decoder.decode(frame(), fields: [0])) }
        retired.removeAll()
        XCTAssertNotNil(try decoder.decode(frame(), fields: [0, 1]))
        withExtendedLifetime(current) {}
    }

    func testSizeAndPixelFormatChangesShareOneLifetimeSurfaceBudget() throws {
        let decoder = VMXFrameDecoder()
        let small = frame(InterlacedFixture.smallOpaque, flags: 0, height: 16)
        var oldSize: [CVPixelBuffer] = []
        for _ in 0..<9 { oldSize.append(try XCTUnwrap(decoder.decode(small))) }
        XCTAssertNil(try decoder.decode(frame(), fields: [0, 1]))
        oldSize.removeLast(2)
        var interlaced = try XCTUnwrap(decoder.decode(frame(), fields: [0, 1]))
        XCTAssertEqual(oldSize.count + interlaced.count, 9)
        let alpha = frame(InterlacedFixture.smallAlpha, flags: 2, height: 16)
        var bgra: [CVPixelBuffer] = [try XCTUnwrap(decoder.decode(alpha))]
        XCTAssertEqual(oldSize.count + interlaced.count + bgra.count, VMXFrameDecoder.maximumRetainedFrames)
        try withExtendedLifetime((oldSize, interlaced, bgra)) { XCTAssertNil(try decoder.decode(alpha)) }
        oldSize.removeAll(); interlaced.removeAll(); bgra.removeAll()
        XCTAssertNotNil(try decoder.decode(alpha))
    }

    func testCurrentPoolReuseDoesNotDuplicateRetiringSurfaceReferences() throws {
        let decoder = VMXFrameDecoder()
        let small = frame(InterlacedFixture.smallOpaque, flags: 0, height: 16)
        for _ in 0..<30 { _ = try XCTUnwrap(decoder.decode(small)) }
        let held = try XCTUnwrap(decoder.decode(small))
        decoder.reset()
        var current: [CVPixelBuffer] = []
        for _ in 0..<4 { current += try XCTUnwrap(decoder.decode(frame(), fields: [0, 1])) }
        XCTAssertEqual(current.count, 8)
        XCTAssertNil(try decoder.decode(frame(), fields: [0, 1]))
        current += try XCTUnwrap(decoder.decode(frame(), fields: [1]))
        XCTAssertEqual(current.count + 1, VMXFrameDecoder.maximumRetainedFrames)
        try withExtendedLifetime((held, current)) { XCTAssertNil(try decoder.decode(frame(), fields: [0])) }
    }

    func testScanModeSwitchAndResetHaveNoPreviousFieldPixelsOrHistory() throws {
        let decoder = VMXFrameDecoder()
        let old = try XCTUnwrap(decoder.decode(frame(), fields: [0, 1]))
        let progressive = try XCTUnwrap(decoder.decode(frame(InterlacedFixture.progressive, flags: 0)))
        CVPixelBufferLockBaseAddress(progressive, .readOnly)
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(progressive)?.assumingMemoryBound(to: UInt8.self))
        XCTAssertGreaterThan(Int(pixels[8 * 2 + 1]), Int(pixels[16 * 2 + 1]) + 100)
        let stride = CVPixelBufferGetBytesPerRow(progressive)
        XCTAssertGreaterThan(Int(pixels[stride + 16 * 2 + 1]), Int(pixels[stride + 8 * 2 + 1]) + 100)
        CVPixelBufferUnlockBaseAddress(progressive, .readOnly)
        decoder.reset()
        let lower = try XCTUnwrap(decoder.decode(frame(), fields: [1]))
        guard try assertField(lower[0], brightX: 16, darkX: 8),
              try assertField(old[0], brightX: 8, darkX: 16) else { return }
    }

    func testContradictoryScanHeadersAndMalformedInterlacedEntropyRemainRejected() throws {
        let decoder = VMXFrameDecoder()
        XCTAssertThrowsError(try decoder.decode(frame(InterlacedFixture.interlaced, flags: 0)))
        XCTAssertThrowsError(try decoder.decode(frame(InterlacedFixture.progressive, flags: 1)))
        for end in 0..<InterlacedFixture.interlaced.count {
            XCTAssertThrowsError(try decoder.decode(frame(Data(InterlacedFixture.interlaced.prefix(end)))))
        }
        var corrupt = InterlacedFixture.interlaced
        let dcHeader = corrupt[0] == 3 ? 5 : 3
        let length = (0..<4).reduce(0) { $0 | Int(corrupt[dcHeader + $1]) << ($1 * 8) }
        corrupt.replaceSubrange((dcHeader + 4)..<(dcHeader + 4 + length), with: repeatElement(UInt8(0), count: length))
        XCTAssertThrowsError(try decoder.decode(frame(corrupt)))
    }

    private func assertField(_ image: CVPixelBuffer, brightX: Int, darkX: Int,
                             file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_422YpCbCr8, file: file, line: line)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, .readOnly), kCVReturnSuccess, file: file, line: line)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self))
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<480 {
            for (x, expected) in [(brightX, 220), (darkX, 32)] {
                let actual = Int(pixels[y * stride + x * 2 + 1])
                guard abs(actual - expected) <= 3 else {
                    XCTFail("First field mismatch at x=\(x), y=\(y), stride=\(stride): Y=\(actual), expected \(expected) ±3", file: file, line: line)
                    return false
                }
            }
        }
        return true
    }
}

private enum InterlacedFixture {
    // Existing upstream 32x16 BT.709 fixtures, kept small to exercise pool-key
    // changes in geometry and UYVY/BGRA independently of interlaced entropy.
    static let smallOpaque = Data(base64Encoded: "AwMBUAEOAAAAAST2d7ABujwoPADWoiAbAAAApQfqD9QfqD9QfqD9QfqD0NQfqD9QfqD4gEAA")!
    static let smallAlpha = Data(base64Encoded: "AwMBUAEQAAAAAST2d7ABujwoPADWoiD//x4AAAClB+oP1B+oP1B+oP1B+oPQ1B+oP1B+oPiAQACAIAA=")!

    static let interlaced = Data(base64Encoded: """
        AwMCYh4SAAAAAYABeQC8eAXkAvGAAID+AID+EgAAAAGAAXkAvHgF5ALxgACA/gCA/hIAAAABgAF5ALx4BeQC8YAAgP4AgP4SAAAAAYABeQC8eAXkAvGAAID+
        AID+EgAAAAGAAXkAvHgF5ALxgACA/gCA/hIAAAABgAF5ALx4BeQC8YAAgP4AgP4SAAAAAYABeQC8eAXkAvGAAID+AID+EgAAAAGAAXkAvHgF5ALxgACA/gCA
        /hIAAAABgAF5ALx4BeQC8YAAgP4AgP4SAAAAAYABeQC8eAXkAvGAAID+AID+EgAAAAGAAXkAvHgF5ALxgACA/gCA/hIAAAABgAF5ALx4BeQC8YAAgP4AgP4S
        AAAAAYABeQC8eAXkAvGAAID+AID+EgAAAAGAAXkAvHgF5ALxgACA/gCA/hIAAAABgAF5ALx4BeQC8YAAgP4AgP4SAAAAAYGAXkAvHgF5ALwAAID+AID+EgAA
        AAGBgF5ALx4BeQC8AACA/gCA/hIAAAABgYBeQC8eAXkAvAAAgP4AgP4SAAAAAYGAXkAvHgF5ALwAAID+AID+EgAAAAGBgF5ALx4BeQC8AACA/gCA/hIAAAAB
        gYBeQC8eAXkAvAAAgP4AgP4SAAAAAYGAXkAvHgF5ALwAAID+AID+EgAAAAGBgF5ALx4BeQC8AACA/gCA/hIAAAABgYBeQC8eAXkAvAAAgP4AgP4SAAAAAYGA
        XkAvHgF5ALwAAID+AID+EgAAAAGBgF5ALx4BeQC8AACA/gCA/hIAAAABgYBeQC8eAXkAvAAAgP4AgP4SAAAAAYGAXkAvHgF5ALwAAID+AID+EgAAAAGBgF5A
        Lx4BeQC8AACA/gCA/hIAAAABgYBeQC8eAXkAvAAAgP4AgP4JAAAAgCAAgEAAgEAACQAAAIAgAIBAAIBAAAkAAACAIACAQACAQAAJAAAAgCAAgEAAgEAACQAA
        AIAgAIBAAIBAAAkAAACAIACAQACAQAAJAAAAgCAAgEAAgEAACQAAAIAgAIBAAIBAAAkAAACAIACAQACAQAAJAAAAgCAAgEAAgEAACQAAAIAgAIBAAIBAAAkA
        AACAIACAQACAQAAJAAAAgCAAgEAAgEAACQAAAIAgAIBAAIBAAAkAAACAIACAQACAQAAJAAAAgCAAgEAAgEAACQAAAIAgAIBAAIBAAAkAAACAIACAQACAQAAJ
        AAAAgCAAgEAAgEAACQAAAIAgAIBAAIBAAAkAAACAIACAQACAQAAJAAAAgCAAgEAAgEAACQAAAIAgAIBAAIBAAAkAAACAIACAQACAQAAJAAAAgCAAgEAAgEAA
        CQAAAIAgAIBAAIBAAAkAAACAIACAQACAQAAJAAAAgCAAgEAAgEAACQAAAIAgAIBAAIBAAAkAAACAIACAQACAQAA=
        """, options: .ignoreUnknownCharacters)!
    static let progressive = Data(base64Encoded: """
        AwMBYh4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4R
        AAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC
        9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3A
        XgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4A
        gP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAA
        AYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5
        gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAAgP4AgP4RAAAAAYAC9wF5gL3AXgAA
        gP4AgP43AAAAgQgETMB1igErHAGVh4BETAdIoBKRwBlICeARMwHWKASscAZWHgERMB0igEpHAGUgXIBAAIBAADcAAACBCARMwHWKASscAZWHgERMB0igEpHA
        GUgJ4BEzAdYoBKxwBlYeAREwHSKASkcAZSBcgEAAgEAANwAAAIEIBEzAdYoBKxwBlYeAREwHSKASkcAZSAngETMB1igErHAGVh4BETAdIoBKRwBlIFyAQACA
        QAA3AAAAgQgETMB1igErHAGVh4BETAdIoBKRwBlICeARMwHWKASscAZWHgERMB0igEpHAGUgXIBAAIBAADcAAACBCARMwHWKASscAZWHgERMB0igEpHAGUgJ
        4BEzAdYoBKxwBlYeAREwHSKASkcAZSBcgEAAgEAANwAAAIEIBEzAdYoBKxwBlYeAREwHSKASkcAZSAngETMB1igErHAGVh4BETAdIoBKRwBlIFyAQACAQAA3
        AAAAgQgETMB1igErHAGVh4BETAdIoBKRwBlICeARMwHWKASscAZWHgERMB0igEpHAGUgXIBAAIBAADcAAACBCARMwHWKASscAZWHgERMB0igEpHAGUgJ4BEz
        AdYoBKxwBlYeAREwHSKASkcAZSBcgEAAgEAANwAAAIEIBEzAdYoBKxwBlYeAREwHSKASkcAZSAngETMB1igErHAGVh4BETAdIoBKRwBlIFyAQACAQAA3AAAA
        gQgETMB1igErHAGVh4BETAdIoBKRwBlICeARMwHWKASscAZWHgERMB0igEpHAGUgXIBAAIBAADcAAACBCARMwHWKASscAZWHgERMB0igEpHAGUgJ4BEzAdYo
        BKxwBlYeAREwHSKASkcAZSBcgEAAgEAANwAAAIEIBEzAdYoBKxwBlYeAREwHSKASkcAZSAngETMB1igErHAGVh4BETAdIoBKRwBlIFyAQACAQAA3AAAAgQgE
        TMB1igErHAGVh4BETAdIoBKRwBlICeARMwHWKASscAZWHgERMB0igEpHAGUgXIBAAIBAADcAAACBCARMwHWKASscAZWHgERMB0igEpHAGUgJ4BEzAdYoBKxw
        BlYeAREwHSKASkcAZSBcgEAAgEAANwAAAIEIBEzAdYoBKxwBlYeAREwHSKASkcAZSAngETMB1igErHAGVh4BETAdIoBKRwBlIFyAQACAQAA3AAAAgQgETMB1
        igErHAGVh4BETAdIoBKRwBlICeARMwHWKASscAZWHgERMB0igEpHAGUgXIBAAIBAADcAAACBCARMwHWKASscAZWHgERMB0igEpHAGUgJ4BEzAdYoBKxwBlYe
        AREwHSKASkcAZSBcgEAAgEAANwAAAIEIBEzAdYoBKxwBlYeAREwHSKASkcAZSAngETMB1igErHAGVh4BETAdIoBKRwBlIFyAQACAQAA3AAAAgQgETMB1igEr
        HAGVh4BETAdIoBKRwBlICeARMwHWKASscAZWHgERMB0igEpHAGUgXIBAAIBAADcAAACBCARMwHWKASscAZWHgERMB0igEpHAGUgJ4BEzAdYoBKxwBlYeAREw
        HSKASkcAZSBcgEAAgEAANwAAAIEIBEzAdYoBKxwBlYeAREwHSKASkcAZSAngETMB1igErHAGVh4BETAdIoBKRwBlIFyAQACAQAA3AAAAgQgETMB1igErHAGV
        h4BETAdIoBKRwBlICeARMwHWKASscAZWHgERMB0igEpHAGUgXIBAAIBAADcAAACBCARMwHWKASscAZWHgERMB0igEpHAGUgJ4BEzAdYoBKxwBlYeAREwHSKA
        SkcAZSBcgEAAgEAANwAAAIEIBEzAdYoBKxwBlYeAREwHSKASkcAZSAngETMB1igErHAGVh4BETAdIoBKRwBlIFyAQACAQAA3AAAAgQgETMB1igErHAGVh4BE
        TAdIoBKRwBlICeARMwHWKASscAZWHgERMB0igEpHAGUgXIBAAIBAADcAAACBCARMwHWKASscAZWHgERMB0igEpHAGUgJ4BEzAdYoBKxwBlYeAREwHSKASkcA
        ZSBcgEAAgEAANwAAAIEIBEzAdYoBKxwBlYeAREwHSKASkcAZSAngETMB1igErHAGVh4BETAdIoBKRwBlIFyAQACAQAA3AAAAgQgETMB1igErHAGVh4BETAdI
        oBKRwBlICeARMwHWKASscAZWHgERMB0igEpHAGUgXIBAAIBAADcAAACBCARMwHWKASscAZWHgERMB0igEpHAGUgJ4BEzAdYoBKxwBlYeAREwHSKASkcAZSBc
        gEAAgEAANwAAAIEIBEzAdYoBKxwBlYeAREwHSKASkcAZSAngETMB1igErHAGVh4BETAdIoBKRwBlIFyAQACAQAA=
        """, options: .ignoreUnknownCharacters)!
}
