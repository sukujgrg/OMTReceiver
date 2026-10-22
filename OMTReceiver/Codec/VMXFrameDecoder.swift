import CoreMedia
import CoreVideo
import Foundation

/// Worker-confined adapter. Ten IOSurface buffers bound frames retained by the
/// decoder, future display samples and the currently displayed image together.
final class VMXFrameDecoder {
    static let maximumRetainedFrames = 10
    private var native: OpaquePointer?
    private var key: String?
    private var pool: CVPixelBufferPool?

    func decode(_ frame: OMTVideoFrame) throws -> CVPixelBuffer? {
        let fps = Double(frame.frameRateN) / Double(max(1, frame.frameRateD))
        guard frame.codec == OMTCodec.vmx1, (16...1920).contains(frame.width), frame.width % 2 == 0,
              (16...1080).contains(frame.height), frame.frameRateN > 0, frame.frameRateD > 0,
              fps <= 60, frame.flags & ~UInt32(6) == 0,
              [0, 601, 709].contains(frame.colorSpace), frame.payload.count <= 16 * 1024 * 1024 else {
            throw PlaybackFailure.unsupportedVideo
        }
        let alpha = frame.flags & 2 != 0
        let format = alpha ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_422YpCbCr8
        let nextKey = "\(frame.width):\(frame.height):\(frame.colorSpace):\(format)"
        if nextKey != key {
            reset()
            guard let decoder = OMTVMXDecoderCreate(Int32(frame.width), Int32(frame.height), Int32(frame.colorSpace)) else {
                throw PlaybackFailure.allocation
            }
            native = decoder
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: frame.width,
                kCVPixelBufferHeightKey as String: frame.height,
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
                reset(); throw PlaybackFailure.allocation
            }
            key = nextKey
        }
        guard let native, let pool else { throw PlaybackFailure.allocation }
        var image: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: Self.maximumRetainedFrames] as CFDictionary, &image)
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let image,
              CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess else { throw PlaybackFailure.allocation }
        let stride = CVPixelBufferGetBytesPerRow(image)
        let result: Int32 = frame.payload.withUnsafeBytes { bytes in
            OMTVMXDecoderDecode(native, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, frame.flags,
                CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self),
                stride * frame.height, stride)
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        guard result == 0 else { throw PlaybackFailure.malformedVideo(Int(result)) }
        let bt709 = frame.colorSpace == 709 || (frame.colorSpace == 0 && frame.height >= 720)
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey,
            bt709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey,
            bt709 ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        if frame.aspectRatio.isFinite, frame.aspectRatio > 0, frame.aspectRatio <= 8 {
            let pixelRatio = Double(frame.aspectRatio) * Double(frame.height) / Double(frame.width)
            CVBufferSetAttachment(image, kCVImageBufferPixelAspectRatioKey, [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: max(1, Int((pixelRatio * 10000).rounded())),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: 10000
            ] as CFDictionary, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(image, kCVImageBufferPixelAspectRatioKey)
        }
        return image
    }

    func reset() {
        if let native { OMTVMXDecoderDestroy(native) }
        native = nil; pool = nil; key = nil
    }
    deinit { reset() }
}
