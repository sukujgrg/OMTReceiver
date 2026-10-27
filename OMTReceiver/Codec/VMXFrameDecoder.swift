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
    private var poolID: UInt64?
    private var nextPoolID: UInt64 = 0
    private final class SurfaceReference {
        weak var image: CVPixelBuffer?
        let poolID: UInt64
        init(_ image: CVPixelBuffer, poolID: UInt64) { self.image = image; self.poolID = poolID }
    }
    // CoreVideo retains released current-pool buffers for reuse. Once the pool
    // retires, weak refs survive only while a renderer/caller still owns pixels.
    // Keep them across reset so changing format cannot escape the global cap.
    private var surfaces: [SurfaceReference] = []

    /// Existing single-image callers receive the first spatial field for an
    /// interlaced frame. Playback supplies its explicit temporal field order.
    func decode(_ frame: OMTVideoFrame) throws -> CVPixelBuffer? {
        try decode(frame, fields: [frame.flags & 1 != 0 ? 0 : nil])?.first
    }

    /// Reserve one surface per output from the same global bounded pool. Decode
    /// into the first output, copy the alternate field out, then bob the first
    /// field in-place. No extra woven surface reduces native preparation lead.
    /// Allocation pressure returns nil without decoding a partial batch.
    func decode(_ frame: OMTVideoFrame, fields: [Int?]) throws -> [CVPixelBuffer]? {
        let interlaced = frame.flags & 1 != 0
        guard frame.codec == OMTCodec.vmx1, (16...1920).contains(frame.width), frame.width % 2 == 0,
              (16...1080).contains(frame.height),
              OMTFrameRate.isValid(numerator: frame.frameRateN, denominator: frame.frameRateD, maximum: 60),
              frame.flags & ~UInt32(7) == 0,
              !interlaced || [480, 576, 1080].contains(frame.height),
              [0, 601, 709].contains(frame.colorSpace), frame.payload.count <= 16 * 1024 * 1024,
              (1...2).contains(fields.count),
              interlaced ? fields.allSatisfy({ $0 == 0 || $0 == 1 }) : fields.count == 1 && fields[0] == nil else {
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
            nextPoolID &+= 1
            poolID = nextPoolID
            key = nextKey
        }
        guard let native, let pool, let poolID else { throw PlaybackFailure.allocation }
        var buffers: [CVPixelBuffer] = []
        for _ in 0..<fields.count {
            surfaces.removeAll { $0.image == nil }
            let retiring = surfaces.filter { $0.poolID != poolID }.count
            let limit = Self.maximumRetainedFrames - retiring
            guard limit > 0 else { return nil }
            var image: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                [kCVPixelBufferPoolAllocationThresholdKey as String: limit] as CFDictionary, &image)
            if status == kCVReturnWouldExceedAllocationThreshold { return nil }
            guard status == kCVReturnSuccess, let image else { throw PlaybackFailure.allocation }
            if !surfaces.contains(where: { $0.image === image }) {
                surfaces.append(SurfaceReference(image, poolID: poolID))
            }
            buffers.append(image)
        }
        let woven = buffers[0]
        guard CVPixelBufferLockBaseAddress(woven, []) == kCVReturnSuccess else { throw PlaybackFailure.allocation }
        let stride = CVPixelBufferGetBytesPerRow(woven)
        let result: Int32 = frame.payload.withUnsafeBytes { bytes in
            OMTVMXDecoderDecode(native, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, frame.flags,
                CVPixelBufferGetBaseAddress(woven)?.assumingMemoryBound(to: UInt8.self),
                stride * frame.height, stride)
        }
        CVPixelBufferUnlockBaseAddress(woven, [])
        guard result == 0 else { throw PlaybackFailure.malformedVideo(Int(result)) }
        let outputs = buffers
        if interlaced {
            // The alternate field must leave the original woven image before
            // in-place bob overwrites it. Hold one writable source lock; never
            // nest a second lock when the first output aliases that source.
            guard CVPixelBufferLockBaseAddress(woven, []) == kCVReturnSuccess else { throw PlaybackFailure.allocation }
            defer { CVPixelBufferUnlockBaseAddress(woven, []) }
            for index in outputs.indices.reversed() {
                let image = outputs[index]
                if index != 0 {
                    guard CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess else { throw PlaybackFailure.allocation }
                }
                let outputStride = CVPixelBufferGetBytesPerRow(image)
                let result = OMTVMXBob(CVPixelBufferGetBaseAddress(woven)?.assumingMemoryBound(to: UInt8.self),
                    stride * frame.height, stride,
                    CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self),
                    outputStride * frame.height, outputStride, Int32(frame.width), Int32(frame.height),
                    alpha ? 4 : 2, Int32(fields[index]!))
                if index != 0 { CVPixelBufferUnlockBaseAddress(image, []) }
                guard result == 0 else { throw PlaybackFailure.malformedVideo(Int(result)) }
            }
        }
        for image in outputs { tag(image, frame: frame) }
        return outputs
    }

    private func tag(_ image: CVPixelBuffer, frame: OMTVideoFrame) {
        // Bob outputs are ordinary progressive samples. Never ask tvOS to infer
        // deinterlacing from field metadata or retain a pool buffer's old tags.
        CVBufferSetAttachment(image, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
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
    }

    func reset() {
        if let native { OMTVMXDecoderDestroy(native) }
        native = nil; pool = nil; key = nil; poolID = nil
        surfaces.removeAll { $0.image == nil }
    }
    deinit { reset() }
}
