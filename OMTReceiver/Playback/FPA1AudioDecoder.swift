import AVFoundation
import CoreMedia
import Foundation

enum FPA1AudioDecoder {
    /// OMT can carry 32 channels. HDMI monitoring uses the first mono/stereo
    /// pair; inactive channels expand to actual silence, including zero-byte
    /// all-silent packets. Extra channels are validated before being omitted.
    static func samples(_ frame: OMTAudioFrame) throws -> [Float] {
        guard frame.codec == OMTCodec.fpa1, (8000...192000).contains(frame.sampleRate),
              (1...32).contains(frame.channels), frame.samplesPerChannel > 0,
              frame.samplesPerChannel <= frame.sampleRate / 5 else { throw PlaybackFailure.malformedAudio }
        let mask: UInt32 = frame.channels == 32 ? .max : (UInt32(1) << frame.channels) - 1
        guard frame.activeChannels & ~mask == 0 else { throw PlaybackFailure.malformedAudio }
        let active = (frame.activeChannels & mask).nonzeroBitCount
        guard frame.payload.count == active * frame.samplesPerChannel * 4 else { throw PlaybackFailure.malformedAudio }
        let outputChannels = min(2, frame.channels)
        var output = [Float](repeating: 0, count: frame.samplesPerChannel * outputChannels)
        try frame.payload.withUnsafeBytes { bytes in
            var offset = 0
            for channel in 0..<frame.channels where frame.activeChannels & (UInt32(1) << channel) != 0 {
                for sample in 0..<frame.samplesPerChannel {
                    let i = offset + sample * 4
                    let bits = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
                        | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
                    let value = Float(bitPattern: bits)
                    guard value.isFinite else { throw PlaybackFailure.malformedAudio }
                    if channel < outputChannels { output[sample * outputChannels + channel] = value }
                }
                offset += frame.samplesPerChannel * 4
            }
        }
        return output
    }

    static func makeSample(_ frame: OMTAudioFrame, at time: CMTime) throws -> CMSampleBuffer {
        let samples = try samples(frame)
        let channels = min(2, frame.channels)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(frame.sampleRate),
                                        channels: AVAudioChannelCount(channels), interleaved: true) else {
            throw PlaybackFailure.malformedAudio
        }
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr, let description else { throw PlaybackFailure.allocation }
        var block: CMBlockBuffer?
        let byteCount = samples.count * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw PlaybackFailure.allocation }
        let copied = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { throw PlaybackFailure.allocation }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(frame.sampleRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = channels * MemoryLayout<Float>.size
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: frame.samplesPerChannel, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { throw PlaybackFailure.allocation }
        return sample
    }
}
