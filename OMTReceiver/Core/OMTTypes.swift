import Foundation

/// Compressed, self-contained VMX video frame. Timestamp units are 100 ns.
struct OMTVideoFrame: Sendable {
    let timestamp: Int64
    let codec: UInt32
    let width: Int
    let height: Int
    let frameRateN: Int
    let frameRateD: Int
    let aspectRatio: Float
    let flags: UInt32
    let colorSpace: Int
    let payload: Data
}

/// FPA1 keeps only the active planar Float32 channels on the wire. A missing
/// channel is silence, and is expanded by the audio renderer, not the transport.
struct OMTAudioFrame: Sendable {
    let timestamp: Int64
    let codec: UInt32
    let sampleRate: Int
    let samplesPerChannel: Int
    let channels: Int
    let activeChannels: UInt32
    let payload: Data
}

enum OMTPacket: Sendable {
    case video(OMTVideoFrame)
    case audio(OMTAudioFrame)
    case metadata(String)
}

enum OMTConnectionState: Sendable, Equatable {
    case connecting
    case connected
    case failed(String)
    case disconnected
}

enum OMTQuality: String, CaseIterable, Sendable, Identifiable {
    case `default` = "Default"
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }
}

enum OMTCodec {
    static let vmx1: UInt32 = 0x3158_4D56
    static let fpa1: UInt32 = 0x3141_5046
}
